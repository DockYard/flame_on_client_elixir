defmodule FlameOn.Client.NativeProcessorTest do
  use ExUnit.Case, async: true

  alias FlameOn.Client.NativeProcessor

  describe "available?/0" do
    test "returns false when NIF is not loaded" do
      refute NativeProcessor.available?()
    end
  end

  describe "process_stacks/2" do
    test "returns {:error, :nif_not_loaded} when NIF is not loaded" do
      stacks = %{"A;B;C" => 1000, "A;B" => 500}
      assert {:error, :nif_not_loaded} = NativeProcessor.process_stacks(stacks, 0.01)
    end

    test "returns {:error, :nif_not_loaded} with empty stacks" do
      assert {:error, :nif_not_loaded} = NativeProcessor.process_stacks(%{}, 0.01)
    end

    test "returns {:error, :nif_not_loaded} with various threshold values" do
      stacks = %{"root;child" => 100}
      assert {:error, :nif_not_loaded} = NativeProcessor.process_stacks(stacks, 0.0)
      assert {:error, :nif_not_loaded} = NativeProcessor.process_stacks(stacks, 1.0)
      assert {:error, :nif_not_loaded} = NativeProcessor.process_stacks(stacks, 0.005)
    end
  end
end
