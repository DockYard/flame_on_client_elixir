defmodule FlameOn.Client.Collector do
  use GenServer

  require Logger

  alias FlameOn.Client.Capture.Block
  alias FlameOn.Client.Capture.Stack
  alias FlameOn.Client.Capture.Trace
  alias FlameOn.Client.CollapsedStacks
  alias FlameOn.Client.ProfileFilter
  alias FlameOn.Client.Shipper

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def active_trace_count(pid) do
    GenServer.call(pid, :active_trace_count)
  end

  @doc false
  def handle_telemetry(event, measurements, metadata, collector_pid) do
    if List.last(event) == :stop do
      GenServer.cast(
        collector_pid,
        {:telemetry_event, event, measurements, metadata, self()}
      )
    else
      # Start events use call so the caller blocks until tracing is active.
      # Without this, the caller races ahead and intermediate functions are missed.
      GenServer.call(
        collector_pid,
        {:telemetry_event, event, measurements, metadata, self()}
      )
    end
  end

  @impl true
  def init(opts) do
    config = build_config(opts)
    collector_pid = self()
    instance_id = :erlang.unique_integer([:positive])
    handler = config.event_handler

    # Normalize events: both bare lists and {event, opts} tuples
    normalized_events =
      Enum.map(config.events, fn
        {event, opts} when is_list(event) -> {event, opts}
        event when is_list(event) -> {event, []}
      end)

    # Build event_thresholds map: %{event_atoms => threshold_us}
    event_thresholds =
      Map.new(normalized_events, fn {event, opts} ->
        threshold_ms =
          case Keyword.fetch(opts, :threshold_ms) do
            {:ok, ms} -> ms
            :error -> handler.default_threshold_ms(event)
          end

        {event, threshold_ms * 1_000}
      end)

    handler_ids =
      for {event, _opts} <- normalized_events, reduce: [] do
        acc ->
          # Attach the configured start event
          start_id = "flame_on_#{instance_id}_#{Enum.join(event, "_")}"

          :telemetry.attach(
            start_id,
            event,
            &__MODULE__.handle_telemetry/4,
            collector_pid
          )

          # Also attach the corresponding stop event
          stop_event = List.replace_at(event, -1, :stop)
          stop_id = "flame_on_#{instance_id}_#{Enum.join(stop_event, "_")}"

          :telemetry.attach(
            stop_id,
            stop_event,
            &__MODULE__.handle_telemetry/4,
            collector_pid
          )

          [stop_id, start_id | acc]
      end

    {:ok,
     %{
       handler: handler,
       sample_rate: config.sample_rate,
       shipper_pid: config.shipper_pid,
       function_length_threshold: Map.get(config, :function_length_threshold, 0.01),
       active_traces: %{},
       handler_ids: handler_ids,
       event_thresholds: event_thresholds
     }}
  end

  @impl true
  def terminate(_reason, state) do
    for handler_id <- Map.get(state, :handler_ids, []) do
      :telemetry.detach(handler_id)
    end

    :ok
  end

  @impl true
  def handle_call({:telemetry_event, event, measurements, metadata, caller_pid}, _from, state) do
    {reply, new_state} = handle_start_event(event, measurements, metadata, caller_pid, state)
    {:reply, reply, new_state}
  end

  @impl true
  def handle_cast({:telemetry_event, event, _measurements, _metadata, caller_pid}, state) do
    handle_stop_event(caller_pid, state)
  end

  defp handle_start_event(event, measurements, metadata, caller_pid, state) do
    case state.handler.handle(event, measurements, metadata) do
      {:capture, info} ->
        if should_sample?(state.sample_rate) and
             not Map.has_key?(state.active_traces, caller_pid) do
          trace_id = generate_trace_id()
          ref = Process.monitor(caller_pid)

          case Trace.start_trace(caller_pid, self()) do
            :ok ->
              Logger.info(
                "[FlameOn] Capturing trace for #{info.event_name} #{info.event_identifier} (pid: #{inspect(caller_pid)})"
              )

              threshold_us = Map.get(state.event_thresholds, event, 100_000)

              now = System.system_time(:microsecond)

              root_block = %Block{
                id: :erlang.unique_integer([:positive, :monotonic]),
                function: {:root, info.event_name, info.event_identifier},
                absolute_start: now,
                level: 0
              }

              trace_info =
                Map.merge(info, %{
                  trace_id: trace_id,
                  pid: caller_pid,
                  monitor_ref: ref,
                  started_at: now,
                  stack: [root_block],
                  threshold_us: threshold_us
                })

              {:ok, put_in(state, [:active_traces, caller_pid], trace_info)}

            {:error, _reason} ->
              Process.demonitor(ref, [:flush])
              {:ok, state}
          end
        else
          {:ok, state}
        end

      :skip ->
        {:ok, state}
    end
  end

  defp handle_stop_event(caller_pid, state) do
    case Map.pop(state.active_traces, caller_pid) do
      {nil, _} ->
        {:noreply, state}

      {trace, new_active_traces} ->
        Trace.stop_trace(caller_pid)
        Process.demonitor(trace.monitor_ref, [:flush])
        state = %{state | active_traces: new_active_traces}
        finalize_and_ship(trace, state)
        {:noreply, state}
    end
  end

  # Trace messages — call
  @impl true
  def handle_info({:trace_ts, pid, :call, mfa, timestamp}, state) do
    state =
      update_trace(state, pid, fn trace ->
        %{trace | stack: Stack.handle_trace_call(trace.stack, mfa, microseconds(timestamp))}
      end)

    {:noreply, state}
  end

  # Trace messages — return_to
  def handle_info({:trace_ts, pid, :return_to, mfa, timestamp}, state) do
    state =
      update_trace(state, pid, fn trace ->
        if trace.stack != [] and length(trace.stack) >= 2 do
          %{
            trace
            | stack: Stack.handle_trace_return_to(trace.stack, mfa, microseconds(timestamp))
          }
        else
          trace
        end
      end)

    {:noreply, state}
  end

  # Trace messages — process scheduled out (sleep)
  def handle_info({:trace_ts, pid, :out, _mfa, timestamp}, state) do
    state =
      update_trace(state, pid, fn trace ->
        %{trace | stack: Stack.handle_trace_call(trace.stack, :sleep, microseconds(timestamp))}
      end)

    {:noreply, state}
  end

  # Trace messages — process scheduled in (wake from sleep)
  def handle_info({:trace_ts, pid, :in, _mfa, timestamp}, state) do
    state =
      update_trace(state, pid, fn trace ->
        case trace.stack do
          [%Block{function: :sleep} | _] ->
            %{
              trace
              | stack: Stack.handle_trace_return_to(trace.stack, :sleep, microseconds(timestamp))
            }

          _ ->
            trace
        end
      end)

    {:noreply, state}
  end

  # Process finished — finalize and ship
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Map.pop(state.active_traces, pid) do
      {nil, _state} ->
        {:noreply, state}

      {trace, new_active_traces} ->
        Trace.stop_trace(pid)
        state = %{state | active_traces: new_active_traces}
        finalize_and_ship(trace, state)
        {:noreply, state}
    end
  end

  # Ignore other trace messages we don't handle
  def handle_info({:trace_ts, _pid, _type, _info, _timestamp}, state) do
    {:noreply, state}
  end

  def handle_info({:trace_ts, _pid, _type, _info, _extra, _timestamp}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:active_trace_count, _from, state) do
    {:reply, map_size(state.active_traces), state}
  end

  defp finalize_and_ship(trace, state) do
    if trace.stack != [] do
      [root_block] = Stack.finalize_stack(trace.stack)
      duration_us = root_block.duration

      Logger.debug(fn ->
        "[FlameOn] Finalized trace #{trace.event_name} #{trace.event_identifier}\n" <>
          "  root: #{inspect(root_block.function)}\n" <>
          "  duration_us: #{duration_us}\n" <>
          "  threshold_us: #{trace.threshold_us}\n" <>
          "  children: #{length(root_block.children)}\n" <>
          format_block_tree(root_block, "  ")
      end)

      if duration_us >= trace.threshold_us do
        collapsed = CollapsedStacks.convert(root_block)

        Logger.debug(fn ->
          top =
            collapsed
            |> Enum.sort_by(& &1.duration_us, :desc)
            |> Enum.take(20)
            |> Enum.map(fn s -> "  #{s.duration_us}us  #{s.stack_path}" end)
            |> Enum.join("\n")

          "[FlameOn] Collapsed stacks (top 20 by duration):\n#{top}"
        end)

        filtered =
          ProfileFilter.filter(collapsed,
            function_length_threshold: state.function_length_threshold
          )

        Shipper.push(state.shipper_pid, %{
          trace_id: trace.trace_id,
          event_name: trace.event_name,
          event_identifier: trace.event_identifier,
          duration_us: duration_us,
          captured_at: trace.started_at,
          samples: filtered
        })
      end
    end
  end

  defp format_block_tree(%Block{function: func, duration: dur, children: children}, indent) do
    label = CollapsedStacks.format_function(func)
    line = "#{indent}#{label} (#{dur}us)\n"

    child_lines =
      children
      |> Enum.take(20)
      |> Enum.map(&format_block_tree(&1, indent <> "  "))
      |> Enum.join()

    suffix =
      if length(children) > 20, do: "#{indent}  ... #{length(children) - 20} more\n", else: ""

    line <> child_lines <> suffix
  end

  defp update_trace(state, pid, fun) do
    case state.active_traces do
      %{^pid => trace} -> put_in(state, [:active_traces, pid], fun.(trace))
      _ -> state
    end
  end

  defp stop_event?(event), do: List.last(event) == :stop

  defp should_sample?(rate), do: :rand.uniform() < rate

  defp microseconds({mega, secs, micro}),
    do: mega * 1_000_000_000_000 + secs * 1_000_000 + micro

  defp generate_trace_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [
      String.pad_leading(Integer.to_string(a, 16), 8, "0"),
      String.pad_leading(Integer.to_string(b, 16), 4, "0"),
      String.pad_leading(Integer.to_string(c, 16), 4, "0"),
      String.pad_leading(Integer.to_string(d, 16), 4, "0"),
      String.pad_leading(Integer.to_string(e, 16), 12, "0")
    ]
    |> Enum.join("-")
    |> String.downcase()
  end

  defp build_config(opts) do
    defaults = %{
      event_handler: Application.get_env(:flame_on_client, :event_handler, FlameOn.Client.EventHandler.Default),
      shipper_adapter: Application.get_env(:flame_on_client, :shipper_adapter, FlameOn.Client.Shipper.Grpc),
      sample_rate: Application.get_env(:flame_on_client, :sample_rate, 0.01),
      events: Application.get_env(:flame_on_client, :events, []),
      server_url: FlameOn.Client.env_or_config(:server_url, "flameon.ai"),
      use_ssl: FlameOn.Client.env_or_config_bool(:use_ssl, true),
      ingest_token: Application.get_env(:flame_on_client, :ingest_token),
      flush_interval_ms: Application.get_env(:flame_on_client, :flush_interval_ms, 5_000),
      max_batch_size: Application.get_env(:flame_on_client, :max_batch_size, 50),
      max_buffer_size: Application.get_env(:flame_on_client, :max_buffer_size, 500),
      function_length_threshold: Application.get_env(:flame_on_client, :function_length_threshold, 0.01),
      shipper_pid: FlameOn.Client.Shipper
    }

    Map.merge(defaults, Map.new(opts))
  end
end
