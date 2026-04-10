defmodule FlameOn.Client.TraceSession do
  @moduledoc """
  Captures erlang:trace messages and builds streaming collapsed stacks.

  Phase 3 architecture: instead of building a Block tree in memory and
  converting it to collapsed stacks after the trace ends, this module
  builds collapsed stacks incrementally during capture. Memory usage is
  O(P) where P = number of unique stack paths (typically 1K-10K),
  independent of trace event count.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FlameOn.Client.Capture.Trace
  alias FlameOn.Client.NativeProcessor
  alias FlameOn.Client.ProfileFilter
  alias FlameOn.Client.SeqTraceRouter
  alias FlameOn.Client.Shipper

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @default_max_events 500_000
  @default_max_stacks 50_000
  @finalize_timeout_ms 10_000
  @default_max_mailbox_depth 50_000

  # Adaptive degradation thresholds
  @reduced_threshold 100_000
  @minimal_threshold 300_000
  @drop_threshold 500_000

  @impl true
  def init(opts) do
    traced_pid = Keyword.fetch!(opts, :traced_pid)
    trace_info = Keyword.fetch!(opts, :trace_info)
    shipper_pid = Keyword.fetch!(opts, :shipper_pid)
    function_length_threshold = Keyword.fetch!(opts, :function_length_threshold)
    max_events = Keyword.get(opts, :max_events, @default_max_events)
    max_stacks = Keyword.get(opts, :max_stacks, @default_max_stacks)
    adaptive_degradation = Keyword.get(opts, :adaptive_degradation, true)
    seq_trace_label = Keyword.get(opts, :seq_trace_label)
    seq_trace_router = Keyword.get(opts, :seq_trace_router)

    max_mailbox_depth =
      Keyword.get(
        opts,
        :max_mailbox_depth,
        Application.get_env(:flame_on_client, :max_mailbox_depth, @default_max_mailbox_depth)
      )

    case Trace.start_trace(traced_pid, self()) do
      :ok ->
        if seq_trace_label do
          SeqTraceRouter.register(seq_trace_label, self())
        end

        Process.monitor(traced_pid)
        now = System.system_time(:microsecond)

        root_mfa = {:root, trace_info.event_name, trace_info.event_identifier}

        {:ok,
         %{
           traced_pid: traced_pid,
           trace_info: trace_info,
           shipper_pid: shipper_pid,
           function_length_threshold: function_length_threshold,
           max_events: max_events,
           max_stacks: max_stacks,
           max_mailbox_depth: max_mailbox_depth,
           adaptive_degradation: adaptive_degradation,
           event_count: 0,

           # Streaming collapsed stacks state
           call_stack: [root_mfa],
           stacks: %{},
           stack_count: 0,
           current_entry_time: now,
           trace_start: now,
           scheduled_out_at: nil,

           # Cross-process tracking
           seq_trace_label: seq_trace_label,
           seq_trace_router: seq_trace_router,
           pending_calls: %{},
           completed_calls: []
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # Trace messages -- call
  @impl true
  def handle_info({:trace_ts, _pid, :call, mfa, timestamp}, state) do
    if state.event_count >= state.max_events do
      discard_trace(state)
    else
      state = maybe_check_mailbox(state)

      case maybe_degrade(state) do
        :discarded ->
          :discarded

        state ->
          {:noreply,
           %{
             state
             | call_stack: [mfa | state.call_stack],
               current_entry_time: microseconds(timestamp),
               event_count: state.event_count + 1
           }}
      end
    end
  end

  # Trace messages -- return_to
  def handle_info({:trace_ts, _pid, :return_to, mfa, timestamp}, state) do
    if state.event_count >= state.max_events do
      discard_trace(state)
    else
      case maybe_degrade(state) do
        :discarded ->
          :discarded

        state ->
          now = microseconds(timestamp)

          # Calculate duration of the function that just returned
          duration = now - state.current_entry_time

          # Build stack path from current call stack and add to stacks
          {stacks, stack_count} =
            if duration > 0 and state.call_stack != [] do
              path = build_stack_path(state.call_stack)
              add_to_stacks(state.stacks, state.stack_count, state.max_stacks, path, duration)
            else
              {state.stacks, state.stack_count}
            end

          # Pop the call stack back to the return target
          call_stack = pop_stack_to(state.call_stack, mfa)

          {:noreply,
           %{
             state
             | call_stack: call_stack,
               stacks: stacks,
               stack_count: stack_count,
               current_entry_time: now,
               event_count: state.event_count + 1
           }}
      end
    end
  end

  # Trace messages -- process scheduled out (sleep)
  def handle_info({:trace_ts, _pid, :out, _mfa, timestamp}, state) do
    if state.event_count >= state.max_events do
      discard_trace(state)
    else
      {:noreply,
       %{
         state
         | scheduled_out_at: microseconds(timestamp),
           event_count: state.event_count + 1
       }}
    end
  end

  # Trace messages -- process scheduled in (wake from sleep)
  def handle_info({:trace_ts, _pid, :in, _mfa, timestamp}, state) do
    if state.event_count >= state.max_events do
      discard_trace(state)
    else
      if state.scheduled_out_at do
        sleep_duration = microseconds(timestamp) - state.scheduled_out_at
        path = build_stack_path([:sleep | state.call_stack])

        {stacks, stack_count} =
          add_to_stacks(state.stacks, state.stack_count, state.max_stacks, path, sleep_duration)

        {:noreply,
         %{
           state
           | stacks: stacks,
             stack_count: stack_count,
             scheduled_out_at: nil,
             event_count: state.event_count + 1
         }}
      else
        {:noreply, %{state | event_count: state.event_count + 1}}
      end
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

  # seq_trace -- target process receives $gen_call from traced process.
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
        send_timestamp: microseconds(timestamp),
        call_stack_at_send: state.call_stack
      })

    {:noreply, %{state | pending_calls: pending_calls}}
  end

  # seq_trace -- target process sends reply back to traced process.
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

        # Inject the cross-process call into the stacks map
        call_duration = reply_timestamp - pending.send_timestamp
        call_mfa = {:cross_process_call, pending.target_pid, pending.target_name, pending.message_form}
        call_stack_with_call = [call_mfa, :sleep | pending.call_stack_at_send]
        path = build_stack_path(call_stack_with_call)

        {stacks, stack_count} =
          add_to_stacks(state.stacks, state.stack_count, state.max_stacks, path, call_duration)

        {:noreply,
         %{
           state
           | pending_calls: remaining,
             completed_calls: [pending | state.completed_calls],
             stacks: stacks,
             stack_count: stack_count
         }}
    end
  end

  # seq_trace -- ignore other seq_trace messages
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

  # -- Public helper functions (for testing) --

  @doc false
  def build_stack_path(call_stack) do
    call_stack
    |> Enum.reverse()
    |> Enum.map(&format_mfa/1)
    |> Enum.join(";")
  end

  @doc false
  def format_mfa(:sleep), do: "SLEEP"
  def format_mfa({:root, name, id}), do: "#{name} #{id}"

  def format_mfa({:cross_process_call, _pid, name, msg}) do
    "CALL #{format_process_name(name)} #{format_message_form(msg)}"
  end

  def format_mfa({:cross_process_call, _pid, name}) do
    "CALL #{format_process_name(name)}"
  end

  def format_mfa({m, f, a}) when is_atom(m) and is_atom(f) and is_integer(a) do
    "#{m}.#{f}/#{a}"
  end

  def format_mfa(other), do: inspect(other)

  @doc false
  def add_to_stacks(stacks, stack_count, max_stacks, path, duration) do
    case Map.fetch(stacks, path) do
      {:ok, existing} ->
        # Path already exists -- just add duration. No growth.
        {Map.put(stacks, path, existing + duration), stack_count}

      :error when stack_count < max_stacks ->
        # New path, under limit -- add it.
        {Map.put(stacks, path, duration), stack_count + 1}

      :error ->
        # New path, at limit -- evict the smallest entry and add.
        {min_path, _min_dur} = Enum.min_by(stacks, fn {_k, v} -> v end)
        stacks = stacks |> Map.delete(min_path) |> Map.put(path, duration)
        {stacks, stack_count}
    end
  end

  @doc false
  def pop_stack_to(stack, mfa) do
    do_pop_stack_to(stack, mfa, 0)
  end

  # Found the target -- return the stack from this point
  defp do_pop_stack_to([top | _rest] = stack, mfa, _depth) when top == mfa, do: stack

  # Don't pop the last element (root frame) -- preserve it
  defp do_pop_stack_to([last], _mfa, _depth), do: [last]

  # Empty stack -- nothing to pop
  defp do_pop_stack_to([], _mfa, _depth), do: []

  # Pop one frame and keep looking
  defp do_pop_stack_to([_top | rest], mfa, depth) do
    do_pop_stack_to(rest, mfa, depth + 1)
  end

  # -- Private functions --

  defp maybe_check_mailbox(state) do
    if rem(state.event_count, 1000) == 0 and state.event_count > 0 do
      {:message_queue_len, len} = Process.info(self(), :message_queue_len)

      if len > state.max_mailbox_depth do
        Logger.warning(
          "[FlameOn] Trace mailbox overflow (#{len} pending), stopping trace"
        )

        Trace.stop_trace(state.traced_pid)
        state
      else
        state
      end
    else
      state
    end
  end

  defp maybe_degrade(%{adaptive_degradation: false} = state), do: state

  defp maybe_degrade(state) do
    cond do
      state.event_count == @drop_threshold ->
        Trace.stop_trace(state.traced_pid)
        trace = state.trace_info

        Logger.warning(
          "[FlameOn] Trace discarded at #{@drop_threshold} events " <>
            "for #{trace.event_name} #{trace.event_identifier}"
        )

        :discarded

      state.event_count == @minimal_threshold ->
        # Minimal: stop capturing returns (duration tracking disabled)
        try do
          :erlang.trace(state.traced_pid, false, [:return_to])
        rescue
          ArgumentError -> :ok
        end

        Logger.debug("[FlameOn] Trace degraded to minimal fidelity at #{@minimal_threshold} events")
        state

      state.event_count == @reduced_threshold ->
        # Reduce: stop capturing scheduling events
        try do
          :erlang.trace(state.traced_pid, false, [:running])
        rescue
          ArgumentError -> :ok
        end

        Logger.debug("[FlameOn] Trace degraded to reduced fidelity at #{@reduced_threshold} events")
        state

      true ->
        state
    end
  end

  defp discard_trace(state) do
    Trace.stop_trace(state.traced_pid)
    trace = state.trace_info

    Logger.warning(
      "[FlameOn] Trace discarded: exceeded #{state.max_events} events " <>
        "for #{trace.event_name} #{trace.event_identifier}"
    )

    {:stop, :normal, state}
  end

  defp finalize_and_ship(state) do
    # Try to use FinalizationGate if available (Phase 2), otherwise proceed directly
    gate_available? = finalization_gate_available?()

    gate_result =
      if gate_available? do
        FlameOn.Client.FinalizationGate.acquire()
      else
        :ok
      end

    case gate_result do
      :ok ->
        try do
          task =
            Task.async(fn ->
              do_finalize_and_ship(state)
            end)

          case Task.yield(task, @finalize_timeout_ms) || Task.shutdown(task) do
            {:ok, _result} ->
              :ok

            nil ->
              trace = state.trace_info

              Logger.warning(
                "[FlameOn] Trace finalization timed out, discarding " <>
                  "for #{trace.event_name} #{trace.event_identifier}"
              )

              :ok
          end
        after
          if gate_available? do
            FlameOn.Client.FinalizationGate.release()
          end
        end

      :full ->
        Logger.warning("[FlameOn] Finalization gate full, discarding trace")
        :ok
    end
  end

  defp finalization_gate_available? do
    try do
      :persistent_term.get(:flame_on_finalization_count)
      true
    rescue
      ArgumentError -> false
    end
  end

  defp do_finalize_and_ship(state) do
    trace = state.trace_info
    stacks = state.stacks

    total_duration = Enum.sum(Map.values(stacks))

    if total_duration >= trace.threshold_us and map_size(stacks) > 0 do
      log_top_stacks(stacks)

      # Try native processor first, fall back to Elixir
      {samples, profile} = process_stacks(stacks, state.function_length_threshold)

      payload =
        %{
          trace_id: trace.trace_id,
          event_name: trace.event_name,
          event_identifier: trace.event_identifier,
          duration_us: total_duration,
          captured_at: Map.get(trace, :started_at, System.system_time(:microsecond))
        }
        |> put_profile_or_samples(samples, profile)

      Shipper.push(state.shipper_pid, payload)
    end
  end

  # Try the native Zig processor. If it returns a pre-encoded protobuf binary,
  # we pass that directly as :profile. Otherwise fall back to the Elixir
  # ProfileFilter and pass :samples for PprofEncoder to handle downstream.
  defp process_stacks(stacks, threshold) do
    case try_native_processor(stacks, threshold) do
      {:ok, profile_binary} ->
        {nil, profile_binary}

      {:error, _reason} ->
        samples = elixir_filter_stacks(stacks, threshold)
        {samples, nil}
    end
  end

  defp try_native_processor(stacks, threshold) do
    if NativeProcessor.available?() do
      NativeProcessor.process_stacks(stacks, threshold)
    else
      {:error, :nif_not_loaded}
    end
  rescue
    e ->
      Logger.warning("[FlameOn] Native processor crashed: #{inspect(e)}, using Elixir fallback")
      {:error, :native_crash}
  catch
    kind, reason ->
      Logger.warning(
        "[FlameOn] Native processor failed (#{kind}): #{inspect(reason)}, using Elixir fallback"
      )

      {:error, :native_crash}
  end

  defp elixir_filter_stacks(stacks, threshold) do
    samples =
      Enum.map(stacks, fn {path, duration} ->
        %{stack_path: path, duration_us: duration}
      end)

    ProfileFilter.filter(samples, function_length_threshold: threshold)
  end

  defp put_profile_or_samples(payload, nil, profile_binary) when is_binary(profile_binary) do
    Map.put(payload, :profile_binary, profile_binary)
  end

  defp put_profile_or_samples(payload, samples, nil) when is_list(samples) do
    Map.put(payload, :samples, samples)
  end

  defp log_top_stacks(stacks) do
    Logger.debug(fn ->
      top =
        stacks
        |> Enum.sort_by(fn {_path, dur} -> dur end, :desc)
        |> Enum.take(20)
        |> Enum.map(fn {path, dur} -> "  #{dur}us  #{path}" end)
        |> Enum.join("\n")

      "[FlameOn] Collapsed stacks (top 20 by duration):\n#{top}"
    end)
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
            send_timestamp: microseconds(timestamp),
            call_stack_at_send: state.call_stack
          })

        do_drain_seq_trace_messages(%{state | pending_calls: pending_calls})

      {:seq_trace, _label, {:send, _serial, _from_pid, _to, {ref_or_alias, _reply}}, timestamp} ->
        ref = normalize_call_ref(ref_or_alias)

        case Map.pop(state.pending_calls, ref) do
          {nil, _} ->
            do_drain_seq_trace_messages(state)

          {pending, remaining} ->
            reply_timestamp = microseconds(timestamp)
            call_duration = reply_timestamp - pending.send_timestamp
            call_mfa = {:cross_process_call, pending.target_pid, pending.target_name, pending.message_form}
            call_stack_with_call = [call_mfa, :sleep | pending.call_stack_at_send]
            path = build_stack_path(call_stack_with_call)

            {stacks, stack_count} =
              add_to_stacks(state.stacks, state.stack_count, state.max_stacks, path, call_duration)

            do_drain_seq_trace_messages(%{
              state
              | pending_calls: remaining,
                completed_calls: [pending | state.completed_calls],
                stacks: stacks,
                stack_count: stack_count
            })
        end

      {:seq_trace, _label, _info, _timestamp} ->
        do_drain_seq_trace_messages(state)
    after
      0 -> state
    end
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

  defp format_process_name(nil), do: "<process>"
  defp format_process_name(name) when is_atom(name), do: inspect(name)

  defp format_message_form(form) do
    inspect(form, charlists: :as_lists)
  end

  defp microseconds({mega, secs, micro}),
    do: mega * 1_000_000_000_000 + secs * 1_000_000 + micro
end
