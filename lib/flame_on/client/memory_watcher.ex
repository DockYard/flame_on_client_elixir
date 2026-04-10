defmodule FlameOn.Client.MemoryWatcher do
  @moduledoc """
  GenServer that periodically checks `:erlang.memory(:total)`. If memory
  exceeds the configured threshold, it trips the CircuitBreaker to disable
  new traces. When memory drops below 80% of the threshold (hysteresis),
  it re-enables tracing. Also sweeps TraceDedupe expired entries on each tick.
  """

  use GenServer

  require Logger

  alias FlameOn.Client.CircuitBreaker
  alias FlameOn.Client.TraceDedupe

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, default_interval())
    max_bytes = Keyword.get(opts, :max_memory_bytes, default_max_memory_bytes())

    state = %{
      interval_ms: interval,
      max_memory_bytes: max_bytes
    }

    schedule_check(interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:check_memory, state) do
    total_memory = :erlang.memory(:total)

    if total_memory > state.max_memory_bytes do
      unless CircuitBreaker.disabled?() do
        Logger.warning(
          "[FlameOn] Tracing disabled: memory #{div(total_memory, 1_048_576)}MB exceeds limit"
        )
      end

      CircuitBreaker.disable!()
    end

    if total_memory < state.max_memory_bytes * 0.8 do
      if CircuitBreaker.disabled?() do
        Logger.info("[FlameOn] Tracing re-enabled: memory dropped below threshold")
      end

      CircuitBreaker.enable!()
    end

    TraceDedupe.sweep()

    schedule_check(state.interval_ms)
    {:noreply, state}
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check_memory, interval)
  end

  defp default_interval do
    Application.get_env(:flame_on_client, :memory_check_interval_ms, 5_000)
  end

  defp default_max_memory_bytes do
    case Application.get_env(:flame_on_client, :max_memory_bytes) do
      nil -> detect_system_memory()
      bytes -> bytes
    end
  end

  defp detect_system_memory do
    # Try :memsup (from os_mon) if available, fall back to a reasonable default.
    # Use apply/3 to avoid compile-time warning when os_mon isn't loaded.
    if Code.ensure_loaded?(:memsup) do
      try do
        data = apply(:memsup, :get_system_memory_data, [])
        total = Keyword.get(data, :total_memory, 0)

        if total > 0 do
          trunc(total * 0.8)
        else
          default_fallback_memory()
        end
      rescue
        _ -> default_fallback_memory()
      catch
        _, _ -> default_fallback_memory()
      end
    else
      default_fallback_memory()
    end
  end

  # Fallback: 80% of 1 GB
  defp default_fallback_memory, do: trunc(1_073_741_824 * 0.8)
end
