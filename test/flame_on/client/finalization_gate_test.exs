defmodule FlameOn.Client.FinalizationGateTest do
  use ExUnit.Case, async: false

  alias FlameOn.Client.FinalizationGate

  setup do
    FinalizationGate.init(2)
    :ok
  end

  describe "acquire/0" do
    test "allows acquisition when under limit" do
      assert :ok = FinalizationGate.acquire()
    end

    test "allows acquisition up to the max" do
      assert :ok = FinalizationGate.acquire()
      assert :ok = FinalizationGate.acquire()
    end

    test "rejects acquisition when at max" do
      assert :ok = FinalizationGate.acquire()
      assert :ok = FinalizationGate.acquire()
      assert :full = FinalizationGate.acquire()
    end
  end

  describe "release/0" do
    test "allows new acquisition after release" do
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

  describe "init/1 with different limits" do
    test "respects custom max concurrent" do
      FinalizationGate.init(1)

      assert :ok = FinalizationGate.acquire()
      assert :full = FinalizationGate.acquire()
    end

    test "allows higher concurrency with larger limit" do
      FinalizationGate.init(5)

      for _ <- 1..5 do
        assert :ok = FinalizationGate.acquire()
      end

      assert :full = FinalizationGate.acquire()
    end
  end
end
