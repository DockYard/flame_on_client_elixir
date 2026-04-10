defmodule FlameOn.Client.MemoryWatcherTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FlameOn.Client.CircuitBreaker
  alias FlameOn.Client.MemoryWatcher
  alias FlameOn.Client.TraceDedupe

  setup do
    CircuitBreaker.enable!()
    :ets.delete_all_objects(:flame_on_trace_dedupe)

    on_exit(fn ->
      CircuitBreaker.enable!()
    end)

    :ok
  end

  describe "memory threshold" do
    test "disables circuit breaker when memory exceeds threshold" do
      # Set a very low threshold so current memory will exceed it
      refute CircuitBreaker.disabled?()

      capture_log(fn ->
        _watcher =
          start_supervised!(
            {MemoryWatcher, max_memory_bytes: 1, interval_ms: 50},
            id: :test_watcher_disable
          )

        # Wait for at least one check cycle
        Process.sleep(100)

        assert CircuitBreaker.disabled?()
        stop_supervised!(:test_watcher_disable)
      end)
    end

    test "re-enables circuit breaker when memory drops below 80% of threshold" do
      # First trip the breaker, then set a very high threshold
      CircuitBreaker.disable!()
      assert CircuitBreaker.disabled?()

      capture_log(fn ->
        # Set threshold very high so current memory is well below 80%
        _watcher =
          start_supervised!(
            {MemoryWatcher, max_memory_bytes: 100_000_000_000, interval_ms: 50},
            id: :test_watcher_enable
          )

        Process.sleep(100)

        refute CircuitBreaker.disabled?()
        stop_supervised!(:test_watcher_enable)
      end)
    end
  end

  describe "sweep integration" do
    test "sweeps TraceDedupe on each tick" do
      Application.put_env(:flame_on_client, :dedupe_window_seconds, 0)

      # Insert some entries that will be expired
      TraceDedupe.should_trace?("GET /test")
      Process.sleep(10)

      _watcher =
        start_supervised!(
          {MemoryWatcher, max_memory_bytes: 100_000_000_000, interval_ms: 50},
          id: :test_watcher_sweep
        )

      # Wait for sweep to run
      Process.sleep(100)

      # The expired entry should have been swept, allowing re-trace
      assert TraceDedupe.should_trace?("GET /test")

      stop_supervised!(:test_watcher_sweep)
    after
      Application.delete_env(:flame_on_client, :dedupe_window_seconds)
    end
  end
end
