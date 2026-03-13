defmodule FlameOn.Client.Capture.Trace do
  def start_trace(pid, tracer_pid) do
    :erlang.trace(pid, true, [
      :call,
      :return_to,
      :running,
      :arity,
      :timestamp,
      {:tracer, tracer_pid}
    ])

    # Apply trace patterns to all currently loaded modules
    :erlang.trace_pattern({:_, :_, :_}, true, [:local])
    # Also apply to any modules loaded after this point (e.g. lazily loaded code)
    :erlang.trace_pattern(:on_load, true, [:local])

    :ok
  rescue
    ArgumentError -> {:error, :process_not_alive}
  end

  def stop_trace(pid) do
    :erlang.trace(pid, false, [:all])
    :ok
  rescue
    ArgumentError -> :ok
  end
end
