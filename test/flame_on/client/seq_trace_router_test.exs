defmodule FlameOn.Client.SeqTraceRouterTest do
  use ExUnit.Case, async: false

  alias FlameOn.Client.SeqTraceRouter

  setup do
    pid = start_supervised!(SeqTraceRouter)
    %{router: pid}
  end

  describe "register/2 and unregister/1" do
    test "registers a label to a session pid" do
      assert :ok = SeqTraceRouter.register(42, self())
    end

    test "unregisters a label" do
      SeqTraceRouter.register(42, self())
      assert :ok = SeqTraceRouter.unregister(42)
    end
  end

  describe "seq_trace message forwarding" do
    test "forwards seq_trace messages to the registered session", %{router: router} do
      SeqTraceRouter.register(123, self())

      # Simulate a seq_trace message arriving at the router
      send(router, {:seq_trace, 123, {:send, {0, 1}, self(), self(), :test_msg}, {0, 0, 1000}})

      assert_receive {:seq_trace, 123, {:send, {0, 1}, _, _, :test_msg}, {0, 0, 1000}}, 1000
    end

    test "does not forward messages for unregistered labels", %{router: router} do
      send(router, {:seq_trace, 999, {:send, {0, 1}, self(), self(), :msg}, {0, 0, 1000}})

      refute_receive {:seq_trace, _, _, _}, 100
    end

    test "stops forwarding after unregister", %{router: router} do
      SeqTraceRouter.register(42, self())
      SeqTraceRouter.unregister(42)

      send(router, {:seq_trace, 42, {:send, {0, 1}, self(), self(), :msg}, {0, 0, 1000}})

      refute_receive {:seq_trace, _, _, _}, 100
    end
  end

  describe "sets itself as system tracer" do
    test "registers as the seq_trace system tracer on start", %{router: router} do
      assert :seq_trace.get_system_tracer() == router
    end
  end

  describe "ETS-based registration" do
    test "register and unregister are direct ETS operations without message passing" do
      # These should return immediately without going through the GenServer
      assert :ok = SeqTraceRouter.register(100, self())
      assert :ok = SeqTraceRouter.register(200, self())
      assert :ok = SeqTraceRouter.unregister(100)

      # Label 200 should still be registered
      assert [{200, _}] = :ets.lookup(FlameOn.Client.SeqTraceRouter, 200)
      # Label 100 should be gone
      assert [] = :ets.lookup(FlameOn.Client.SeqTraceRouter, 100)
    end
  end
end
