defmodule FlameOn.Client.TraceSession do
  use GenServer, restart: :temporary

  require Logger

  alias FlameOn.Client.Capture.Block
  alias FlameOn.Client.Capture.Stack
  alias FlameOn.Client.Capture.Trace
  alias FlameOn.Client.CollapsedStacks
  alias FlameOn.Client.ProfileFilter
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

    case Trace.start_trace(traced_pid, self()) do
      :ok ->
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
           stack: [root_block]
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # Trace messages — call
  @impl true
  def handle_info({:trace_ts, _pid, :call, mfa, timestamp}, state) do
    {:noreply, %{state | stack: Stack.handle_trace_call(state.stack, mfa, microseconds(timestamp))}}
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
    finalize_and_ship(state)
    {:stop, :normal, state}
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
    finalize_and_ship(state)
    {:stop, :normal, state}
  end

  defp finalize_and_ship(state) do
    trace = state.trace_info

    if state.stack != [] do
      [root_block] = Stack.finalize_stack(state.stack)
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

  defp microseconds({mega, secs, micro}),
    do: mega * 1_000_000_000_000 + secs * 1_000_000 + micro
end
