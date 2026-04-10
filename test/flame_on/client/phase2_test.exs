defmodule FlameOn.Client.Phase2Test do
  @moduledoc """
  Combined tests for all Phase 2 safety modules:
  CircuitBreaker, TraceDedupe, FinalizationGate, and MemoryWatcher.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FlameOn.Client.CircuitBreaker
  alias FlameOn.Client.TraceDedupe
  alias FlameOn.Client.FinalizationGate
  alias FlameOn.Client.MemoryWatcher

  # ── CircuitBreaker ──────────────────────────────────────────────────

  describe "CircuitBreaker - init/0" do
    test "initializes in enabled state" do
      CircuitBreaker.init()
      refute CircuitBreaker.disabled?()
    end
  end

  describe "CircuitBreaker - enable!/0 and disable!/0" do
    setup do
      CircuitBreaker.init()
      :ok
    end

    test "disable! sets the breaker to disabled" do
      CircuitBreaker.disable!()
      assert CircuitBreaker.disabled?()
    end

    test "enable! re-enables after disable" do
      CircuitBreaker.disable!()
      assert CircuitBreaker.disabled?()

      CircuitBreaker.enable!()
      refute CircuitBreaker.disabled?()
    end
  end

  describe "CircuitBreaker - disabled?/0" do
    setup do
      CircuitBreaker.init()
      :ok
    end

    test "returns false when enabled" do
      refute CircuitBreaker.disabled?()
    end

    test "returns true when disabled" do
      CircuitBreaker.disable!()
      assert CircuitBreaker.disabled?()
    end

    test "full toggle cycle works" do
      refute CircuitBreaker.disabled?()
      CircuitBreaker.disable!()
      assert CircuitBreaker.disabled?()
      CircuitBreaker.enable!()
      refute CircuitBreaker.disabled?()
    end
  end

  # ── TraceDedupe ─────────────────────────────────────────────────────

  describe "TraceDedupe - dedup within window" do
    setup do
      :ets.delete_all_objects(:flame_on_trace_dedupe)
      :ok
    end

    test "allows first trace for an identifier" do
      assert TraceDedupe.should_trace?("GET /phase2/users")
    end

    test "rejects duplicate within the window" do
      assert TraceDedupe.should_trace?("GET /phase2/dup")
      refute TraceDedupe.should_trace?("GET /phase2/dup")
    end

    test "allows different identifiers independently" do
      assert TraceDedupe.should_trace?("GET /phase2/a")
      assert TraceDedupe.should_trace?("GET /phase2/b")
    end
  end

  describe "TraceDedupe - allow after window" do
    setup do
      :ets.delete_all_objects(:flame_on_trace_dedupe)
      :ok
    end

    test "allows trace after the dedupe window expires" do
      Application.put_env(:flame_on_client, :dedupe_window_seconds, 1)

      assert TraceDedupe.should_trace?("GET /phase2/expiring")
      Process.sleep(2100)
      assert TraceDedupe.should_trace?("GET /phase2/expiring")
    after
      Application.delete_env(:flame_on_client, :dedupe_window_seconds)
    end
  end

  describe "TraceDedupe - sweep clears old entries" do
    setup do
      :ets.delete_all_objects(:flame_on_trace_dedupe)
      :ok
    end

    test "sweep removes expired entries" do
      Application.put_env(:flame_on_client, :dedupe_window_seconds, 1)

      assert TraceDedupe.should_trace?("GET /phase2/sweep_target")
      Process.sleep(2100)

      swept = TraceDedupe.sweep()
      assert swept >= 1

      # After sweep the identifier is allowed again
      assert TraceDedupe.should_trace?("GET /phase2/sweep_target")
    after
      Application.delete_env(:flame_on_client, :dedupe_window_seconds)
    end

    test "sweep does not remove entries within the window" do
      Application.put_env(:flame_on_client, :dedupe_window_seconds, 3600)

      assert TraceDedupe.should_trace?("GET /phase2/active")

      swept = TraceDedupe.sweep()
      assert swept == 0

      # Entry still present, duplicate rejected
      refute TraceDedupe.should_trace?("GET /phase2/active")
    after
      Application.delete_env(:flame_on_client, :dedupe_window_seconds)
    end
  end

  describe "TraceDedupe - disabled mode always allows" do
    setup do
      :ets.delete_all_objects(:flame_on_trace_dedupe)
      :ok
    end

    test "should_trace? always returns true when dedupe_enabled is false" do
      Application.put_env(:flame_on_client, :dedupe_enabled, false)

      assert TraceDedupe.should_trace?("GET /phase2/disabled")
      assert TraceDedupe.should_trace?("GET /phase2/disabled")
      assert TraceDedupe.should_trace?("GET /phase2/disabled")
    after
      Application.delete_env(:flame_on_client, :dedupe_enabled)
    end
  end

  # ── FinalizationGate ────────────────────────────────────────────────

  describe "FinalizationGate - acquire up to max" do
    setup do
      FinalizationGate.init(2)
      :ok
    end

    test "allows acquisition under limit" do
      assert :ok = FinalizationGate.acquire()
    end

    test "allows acquisition up to the max" do
      assert :ok = FinalizationGate.acquire()
      assert :ok = FinalizationGate.acquire()
    end
  end

  describe "FinalizationGate - reject at max" do
    setup do
      FinalizationGate.init(2)
      :ok
    end

    test "returns :full when at max concurrent" do
      assert :ok = FinalizationGate.acquire()
      assert :ok = FinalizationGate.acquire()
      assert :full = FinalizationGate.acquire()
    end
  end

  describe "FinalizationGate - release frees slot" do
    setup do
      FinalizationGate.init(2)
      :ok
    end

    test "release allows a new acquire" do
      assert :ok = FinalizationGate.acquire()
      assert :ok = FinalizationGate.acquire()
      assert :full = FinalizationGate.acquire()

      assert :ok = FinalizationGate.release()
      assert :ok = FinalizationGate.acquire()
    end

    test "multiple releases open multiple slots" do
      assert :ok = FinalizationGate.acquire()
      assert :ok = FinalizationGate.acquire()

      assert :ok = FinalizationGate.release()
      assert :ok = FinalizationGate.release()

      assert :ok = FinalizationGate.acquire()
      assert :ok = FinalizationGate.acquire()
      assert :full = FinalizationGate.acquire()
    end
  end

  # ── MemoryWatcher ───────────────────────────────────────────────────

  describe "MemoryWatcher - starts and runs" do
    setup do
      CircuitBreaker.init()
      :ok
    end

    test "starts successfully as a GenServer" do
      pid =
        start_supervised!(
          {MemoryWatcher, max_memory_bytes: 100_000_000_000, interval_ms: 5_000},
          id: :phase2_smoke_watcher
        )

      assert Process.alive?(pid)
      stop_supervised!(:phase2_smoke_watcher)
    end

    test "disables circuit breaker when memory exceeds threshold" do
      refute CircuitBreaker.disabled?()

      capture_log(fn ->
        _pid =
          start_supervised!(
            {MemoryWatcher, max_memory_bytes: 1, interval_ms: 50},
            id: :phase2_disable_watcher
          )

        Process.sleep(100)
        assert CircuitBreaker.disabled?()
        stop_supervised!(:phase2_disable_watcher)
      end)
    end

    test "re-enables circuit breaker when memory drops below 80% of threshold" do
      CircuitBreaker.disable!()
      assert CircuitBreaker.disabled?()

      capture_log(fn ->
        _pid =
          start_supervised!(
            {MemoryWatcher, max_memory_bytes: 100_000_000_000, interval_ms: 50},
            id: :phase2_enable_watcher
          )

        Process.sleep(100)
        refute CircuitBreaker.disabled?()
        stop_supervised!(:phase2_enable_watcher)
      end)
    end
  end
end
