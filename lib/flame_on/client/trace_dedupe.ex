defmodule FlameOn.Client.TraceDedupe do
  @moduledoc """
  ETS-based deduplication with configurable TTL window. Prevents profiling
  the same endpoint repeatedly during error cascades.
  """

  @table :flame_on_trace_dedupe

  def init do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    :ok
  end

  def should_trace?(event_identifier) do
    if enabled?() do
      now = System.monotonic_time(:second)
      win = window()

      case :ets.lookup(@table, event_identifier) do
        [{_, last_traced}] when now - last_traced < win -> false

        _ ->
          :ets.insert(@table, {event_identifier, now})
          true
      end
    else
      true
    end
  end

  def sweep do
    now = System.monotonic_time(:second)
    cutoff = now - window()
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  end

  defp window, do: Application.get_env(:flame_on_client, :dedupe_window_seconds, 60)
  defp enabled?, do: Application.get_env(:flame_on_client, :dedupe_enabled, true)
end
