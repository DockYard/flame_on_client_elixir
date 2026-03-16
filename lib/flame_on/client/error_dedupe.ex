defmodule FlameOn.Client.ErrorDedupe do
  @moduledoc false

  @key {__MODULE__, :seen}

  def duplicate?(%FlameOn.ErrorEvent{} = event, window_ms)
      when is_integer(window_ms) and window_ms > 0 do
    now = System.monotonic_time(:millisecond)
    fingerprint = fingerprint(event)
    seen = prune(Process.get(@key, %{}), now, window_ms)

    case Map.fetch(seen, fingerprint) do
      {:ok, last_seen} when now - last_seen < window_ms ->
        Process.put(@key, seen)
        true

      _ ->
        Process.put(@key, Map.put(seen, fingerprint, now))
        false
    end
  end

  def duplicate?(_event, _window_ms), do: false

  def clear do
    Process.delete(@key)
    :ok
  end

  defp prune(seen, now, window_ms) do
    Enum.reduce(seen, %{}, fn {key, timestamp}, acc ->
      if now - timestamp < window_ms, do: Map.put(acc, key, timestamp), else: acc
    end)
  end

  defp fingerprint(event) do
    exception = List.first(event.exceptions)

    {
      event.message,
      event.route,
      event.severity,
      event.handled,
      event.trace_id,
      exception && exception.type,
      exception && exception.value,
      top_frame(exception)
    }
  end

  defp top_frame(nil), do: nil

  defp top_frame(exception) do
    case exception.stack_trace.frames do
      [%FlameOn.StackFrame{module: module, function: function, file: file, line: line} | _] ->
        {module, function, file, line}

      _ ->
        nil
    end
  end
end
