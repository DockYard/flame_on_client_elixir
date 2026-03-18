defmodule FlameOn.Client.TraceSession do
  use GenServer, restart: :temporary

  require Logger

  alias FlameOn.Client.Capture.Block
  alias FlameOn.Client.Capture.Stack
  alias FlameOn.Client.Capture.Trace
  alias FlameOn.Client.CollapsedStacks
  alias FlameOn.Client.ProfileFilter
  alias FlameOn.Client.SeqTraceRouter
  alias FlameOn.Client.Shipper

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    traced_pid = Keyword.fetch!(opts, :traced_pid)
    trace_info = Keyword.fetch!(opts, :trace_info)
    shipper_pid = Keyword.fetch!(opts, :shipper_pid)
    function_length_threshold = Keyword.fetch!(opts, :function_length_threshold)
    seq_trace_label = Keyword.get(opts, :seq_trace_label)
    seq_trace_router = Keyword.get(opts, :seq_trace_router)

    case Trace.start_trace(traced_pid, self()) do
      :ok ->
        if seq_trace_label do
          SeqTraceRouter.register(seq_trace_label, self())
        end

        Process.monitor(traced_pid)
        now = System.system_time(:microsecond)

        root_block = %Block{
          id: :erlang.unique_integer([:positive, :monotonic]),
          function: {:root, trace_info.event_name, trace_info.event_identifier},
          absolute_start: now,
          level: 0
        }

        {:ok,
         %{
           traced_pid: traced_pid,
           trace_info: trace_info,
           shipper_pid: shipper_pid,
           function_length_threshold: function_length_threshold,
           stack: [root_block],
           seq_trace_label: seq_trace_label,
           seq_trace_router: seq_trace_router,
           pending_calls: %{},
           completed_calls: []
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # Trace messages — call
  @impl true
  def handle_info({:trace_ts, _pid, :call, mfa, timestamp}, state) do
    {:noreply,
     %{state | stack: Stack.handle_trace_call(state.stack, mfa, microseconds(timestamp))}}
  end

  # Trace messages — return_to
  def handle_info({:trace_ts, _pid, :return_to, mfa, timestamp}, state) do
    if state.stack != [] and length(state.stack) >= 2 do
      {:noreply,
       %{state | stack: Stack.handle_trace_return_to(state.stack, mfa, microseconds(timestamp))}}
    else
      {:noreply, state}
    end
  end

  # Trace messages — process scheduled out (sleep)
  def handle_info({:trace_ts, _pid, :out, _mfa, timestamp}, state) do
    {:noreply,
     %{state | stack: Stack.handle_trace_call(state.stack, :sleep, microseconds(timestamp))}}
  end

  # Trace messages — process scheduled in (wake from sleep)
  def handle_info({:trace_ts, _pid, :in, _mfa, timestamp}, state) do
    case state.stack do
      [%Block{function: :sleep} | _] ->
        {:noreply,
         %{
           state
           | stack: Stack.handle_trace_return_to(state.stack, :sleep, microseconds(timestamp))
         }}

      _ ->
        {:noreply, state}
    end
  end

  # Traced process exited
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    state = drain_seq_trace_messages(state)

    if state.seq_trace_label do
      SeqTraceRouter.unregister(state.seq_trace_label)
    end

    finalize_and_ship(state)
    {:stop, :normal, state}
  end

  # seq_trace — target process receives $gen_call from traced process.
  # When erlang tracing is active on the traced process, the :send event from
  # the traced process is consumed by the erlang tracer. We use the target's
  # :receive event instead, which contains the same $gen_call payload.
  # The caller field in $gen_call is {pid, [:alias | ref]} in OTP 24+.
  def handle_info(
        {:seq_trace, _label,
         {:receive, _serial, from_pid, to_pid, {:"$gen_call", {_caller, ref_or_alias}, msg}},
         timestamp},
        %{traced_pid: traced_pid} = state
      )
      when from_pid == traced_pid do
    ref = normalize_call_ref(ref_or_alias)

    pending_calls =
      Map.put(state.pending_calls, ref, %{
        target_pid: to_pid,
        target_name: process_name(to_pid),
        message_form: sanitize_message(msg),
        send_timestamp: microseconds(timestamp)
      })

    {:noreply, %{state | pending_calls: pending_calls}}
  end

  # seq_trace — target process sends reply back to traced process.
  # The :send event from the target has the reference alias as `to` (not the PID).
  # We match on the reference to correlate with the pending $gen_call.
  def handle_info(
        {:seq_trace, _label, {:send, _serial, _from_pid, _to, {ref_or_alias, _reply}}, timestamp},
        state
      ) do
    ref = normalize_call_ref(ref_or_alias)

    case Map.pop(state.pending_calls, ref) do
      {nil, _} ->
        {:noreply, state}

      {pending, remaining} ->
        reply_timestamp = microseconds(timestamp)

        completed = %{
          target_pid: pending.target_pid,
          target_name: pending.target_name,
          message_form: pending.message_form,
          start_timestamp: pending.send_timestamp,
          end_timestamp: reply_timestamp
        }

        {:noreply,
         %{
           state
           | pending_calls: remaining,
             completed_calls: [completed | state.completed_calls]
         }}
    end
  end

  # seq_trace — ignore other seq_trace messages
  def handle_info({:seq_trace, _label, _info, _timestamp}, state) do
    {:noreply, state}
  end

  # Ignore other trace messages
  def handle_info({:trace_ts, _pid, _type, _info, _timestamp}, state) do
    {:noreply, state}
  end

  def handle_info({:trace_ts, _pid, _type, _info, _extra, _timestamp}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast(:stop, state) do
    Trace.stop_trace(state.traced_pid)
    state = drain_seq_trace_messages(state)

    if state.seq_trace_label do
      SeqTraceRouter.unregister(state.seq_trace_label)
    end

    finalize_and_ship(state)
    {:stop, :normal, state}
  end

  defp finalize_and_ship(state) do
    trace = state.trace_info

    if state.stack != [] do
      [root_block] = Stack.finalize_stack(state.stack)
      root_block = inject_completed_calls(root_block, state.completed_calls)
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
          captured_at: Map.get(trace, :started_at, System.system_time(:microsecond)),
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

  # Drain any pending seq_trace messages from the mailbox before finalizing.
  # Seq_trace messages go through the SeqTraceRouter (an extra hop), so they
  # may arrive after the :DOWN or :stop message. We give them a brief window
  # to arrive, then process whatever is available.
  defp drain_seq_trace_messages(%{seq_trace_router: nil} = state), do: state

  defp drain_seq_trace_messages(state) do
    # Flush the router to ensure all pending seq_trace messages have been
    # forwarded to our mailbox. The GenServer.call blocks until the router
    # has processed its entire mailbox up to this point.
    SeqTraceRouter.flush(state.seq_trace_router)
    do_drain_seq_trace_messages(state)
  end

  defp do_drain_seq_trace_messages(state) do
    receive do
      {:seq_trace, _label,
       {:receive, _serial, from_pid, to_pid, {:"$gen_call", {_caller, ref_or_alias}, msg}},
       timestamp}
      when from_pid == state.traced_pid ->
        ref = normalize_call_ref(ref_or_alias)

        pending_calls =
          Map.put(state.pending_calls, ref, %{
            target_pid: to_pid,
            target_name: process_name(to_pid),
            message_form: sanitize_message(msg),
            send_timestamp: microseconds(timestamp)
          })

        do_drain_seq_trace_messages(%{state | pending_calls: pending_calls})

      {:seq_trace, _label, {:send, _serial, _from_pid, _to, {ref_or_alias, _reply}}, timestamp} ->
        ref = normalize_call_ref(ref_or_alias)

        case Map.pop(state.pending_calls, ref) do
          {nil, _} ->
            do_drain_seq_trace_messages(state)

          {pending, remaining} ->
            completed = %{
              target_pid: pending.target_pid,
              target_name: pending.target_name,
              message_form: pending.message_form,
              start_timestamp: pending.send_timestamp,
              end_timestamp: microseconds(timestamp)
            }

            do_drain_seq_trace_messages(%{
              state
              | pending_calls: remaining,
                completed_calls: [completed | state.completed_calls]
            })
        end

      {:seq_trace, _label, _info, _timestamp} ->
        do_drain_seq_trace_messages(state)
    after
      0 -> state
    end
  end

  # Post-process the finalized block tree to inject cross-process call blocks
  # as children of matching sleep blocks. A completed call matches a sleep block
  # when the call's time range falls within the sleep's time range.
  defp inject_completed_calls(block, []), do: block

  defp inject_completed_calls(%Block{} = block, completed_calls) do
    children = Enum.map(block.children, &inject_completed_calls(&1, completed_calls))

    children =
      Enum.map(children, fn
        %Block{function: :sleep} = sleep_block ->
          matching_calls =
            Enum.filter(completed_calls, fn call ->
              call.start_timestamp >= sleep_block.absolute_start and
                call.end_timestamp <=
                  sleep_block.absolute_start + sleep_block.duration
            end)

          if matching_calls == [] do
            sleep_block
          else
            call_children =
              Enum.map(matching_calls, fn call ->
                %Block{
                  id: :erlang.unique_integer([:positive, :monotonic]),
                  function:
                    {:cross_process_call, call.target_pid, call.target_name, call.message_form},
                  absolute_start: call.start_timestamp,
                  duration: call.end_timestamp - call.start_timestamp,
                  level: sleep_block.level + 1,
                  children: []
                }
              end)

            %Block{sleep_block | children: call_children}
          end

        other ->
          other
      end)

    %Block{block | children: children}
  end

  # Sanitize a GenServer.call message for display in the flamegraph.
  # Retains structure (tuples, atoms, numbers) at the top level but replaces
  # maps with %{...}, strings with "...", and nested tuples/lists with
  # "tuple"/"list" to keep labels concise.
  defp sanitize_message(msg), do: do_sanitize(msg, true)

  defp do_sanitize(msg, _top_level?) when is_atom(msg), do: msg
  defp do_sanitize(msg, _top_level?) when is_number(msg), do: msg
  defp do_sanitize(msg, _top_level?) when is_binary(msg), do: "..."
  defp do_sanitize(msg, _top_level?) when is_map(msg), do: "%{...}"
  defp do_sanitize(msg, _top_level?) when is_pid(msg), do: "pid"
  defp do_sanitize(msg, _top_level?) when is_reference(msg), do: "ref"
  defp do_sanitize(msg, _top_level?) when is_function(msg), do: "fn"

  defp do_sanitize(msg, true) when is_tuple(msg) do
    msg
    |> Tuple.to_list()
    |> Enum.map(&do_sanitize(&1, false))
    |> List.to_tuple()
  end

  defp do_sanitize(msg, false) when is_tuple(msg), do: "tuple"

  defp do_sanitize(msg, true) when is_list(msg) do
    Enum.map(msg, &do_sanitize(&1, false))
  end

  defp do_sanitize(msg, false) when is_list(msg), do: "list"

  defp do_sanitize(_msg, _top_level?), do: :_

  # In OTP 24+, GenServer.call uses monitor aliases: [:alias | ref].
  # Normalize to the bare reference for consistent map keys.
  defp normalize_call_ref([:alias | ref]) when is_reference(ref), do: ref
  defp normalize_call_ref(ref) when is_reference(ref), do: ref
  defp normalize_call_ref(other), do: other

  defp process_name(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) ->
        name

      _ ->
        # Fall back to the OTP $initial_call dictionary entry, which gives
        # us the callback module for GenServers (e.g. {MyApp.Worker, :init, 1})
        case Process.info(pid, :dictionary) do
          {:dictionary, dict} ->
            case List.keyfind(dict, :"$initial_call", 0) do
              {:"$initial_call", {mod, _fun, _arity}} -> mod
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  defp microseconds({mega, secs, micro}),
    do: mega * 1_000_000_000_000 + secs * 1_000_000 + micro
end
