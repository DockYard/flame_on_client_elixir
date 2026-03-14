defmodule FlameOn.Client.Collector do
  use GenServer

  require Logger

  alias FlameOn.Client.TraceSessionSupervisor

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
       event_thresholds: event_thresholds,
       trace_session_supervisor: config.trace_session_supervisor
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

  def handle_call(:active_trace_count, _from, state) do
    {:reply, map_size(state.active_traces), state}
  end

  @impl true
  def handle_cast({:telemetry_event, _event, _measurements, _metadata, caller_pid}, state) do
    handle_stop_event(caller_pid, state)
  end

  defp handle_start_event(event, measurements, metadata, caller_pid, state) do
    case state.handler.handle(event, measurements, metadata) do
      {:capture, info} ->
        if should_sample?(state.sample_rate) and
             not Map.has_key?(state.active_traces, caller_pid) do
          trace_id = generate_trace_id()
          threshold_us = Map.get(state.event_thresholds, event, 100_000)

          trace_info =
            Map.merge(info, %{
              trace_id: trace_id,
              threshold_us: threshold_us,
              started_at: System.system_time(:microsecond)
            })

          session_opts = [
            traced_pid: caller_pid,
            trace_info: trace_info,
            shipper_pid: state.shipper_pid,
            function_length_threshold: state.function_length_threshold
          ]

          case TraceSessionSupervisor.start_session(
                 state.trace_session_supervisor,
                 session_opts
               ) do
            {:ok, session_pid} ->
              Logger.info(
                "[FlameOn] Capturing trace for #{info.event_name} #{info.event_identifier} (pid: #{inspect(caller_pid)})"
              )

              Process.monitor(session_pid)
              {:ok, put_in(state, [:active_traces, caller_pid], session_pid)}

            {:error, _reason} ->
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
    case Map.get(state.active_traces, caller_pid) do
      nil ->
        {:noreply, state}

      session_pid ->
        GenServer.cast(session_pid, :stop)
        {:noreply, state}
    end
  end

  # TraceSession exited — clean up active_traces
  @impl true
  def handle_info({:DOWN, _ref, :process, dead_pid, _reason}, state) do
    # Find the caller_pid whose session matches the dead session
    new_active_traces =
      state.active_traces
      |> Enum.reject(fn {_caller_pid, session_pid} -> session_pid == dead_pid end)
      |> Map.new()

    {:noreply, %{state | active_traces: new_active_traces}}
  end

  defp should_sample?(rate), do: :rand.uniform() < rate

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
      shipper_pid: FlameOn.Client.Shipper,
      trace_session_supervisor: FlameOn.Client.TraceSessionSupervisor
    }

    Map.merge(defaults, Map.new(opts))
  end
end
