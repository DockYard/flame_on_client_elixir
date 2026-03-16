defmodule FlameOn.Client.TraceContext do
  @moduledoc false

  @key {__MODULE__, :trace_id}

  def current_trace_id, do: Process.get(@key)

  def put_trace_id(trace_id) when is_binary(trace_id) do
    Process.put(@key, trace_id)
    :ok
  end

  def clear do
    Process.delete(@key)
    :ok
  end
end
