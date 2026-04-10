defmodule FlameOn.Client.TraceDedupeTest do
  use ExUnit.Case, async: false

  alias FlameOn.Client.TraceDedupe

  setup do
    # Clear all entries from the shared ETS table between tests
    :ets.delete_all_objects(:flame_on_trace_dedupe)
    :ok
  end

  describe "should_trace?/1" do
    test "allows first trace for an identifier" do
      assert TraceDedupe.should_trace?("GET /users")
    end

    test "rejects duplicate within the window" do
      assert TraceDedupe.should_trace?("GET /users")
      refute TraceDedupe.should_trace?("GET /users")
    end

    test "allows different identifiers" do
      assert TraceDedupe.should_trace?("GET /users")
      assert TraceDedupe.should_trace?("POST /users")
    end

    test "allows trace after window expires" do
      # Set a very short window for testing.
      # Sleep must be long enough for monotonic_time(:second) to advance
      # past the window boundary.
      Application.put_env(:flame_on_client, :dedupe_window_seconds, 1)

      assert TraceDedupe.should_trace?("GET /expiring_users")
      Process.sleep(2100)
      assert TraceDedupe.should_trace?("GET /expiring_users")
    after
      Application.delete_env(:flame_on_client, :dedupe_window_seconds)
    end

    test "allows all traces when dedupe is disabled" do
      Application.put_env(:flame_on_client, :dedupe_enabled, false)

      assert TraceDedupe.should_trace?("GET /users")
      assert TraceDedupe.should_trace?("GET /users")
      assert TraceDedupe.should_trace?("GET /users")
    after
      Application.delete_env(:flame_on_client, :dedupe_enabled)
    end
  end

  describe "sweep/0" do
    test "removes expired entries" do
      # Use a 1-second window and wait for it to expire.
      # We need to sleep long enough that the monotonic_time(:second) difference
      # is strictly greater than the window, hence 2100ms for a 1s window.
      Application.put_env(:flame_on_client, :dedupe_window_seconds, 1)

      assert TraceDedupe.should_trace?("GET /sweep_users")
      Process.sleep(2100)

      swept = TraceDedupe.sweep()
      assert swept >= 1

      # After sweep, should be allowed again
      assert TraceDedupe.should_trace?("GET /sweep_users")
    after
      Application.delete_env(:flame_on_client, :dedupe_window_seconds)
    end

    test "does not remove entries within the window" do
      Application.put_env(:flame_on_client, :dedupe_window_seconds, 3600)

      assert TraceDedupe.should_trace?("GET /active_users")

      swept = TraceDedupe.sweep()
      assert swept == 0

      # Entry should still be there, so duplicate is rejected
      refute TraceDedupe.should_trace?("GET /active_users")
    after
      Application.delete_env(:flame_on_client, :dedupe_window_seconds)
    end
  end
end
