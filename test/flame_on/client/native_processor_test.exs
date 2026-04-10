defmodule FlameOn.Client.NativeProcessorTest do
  use ExUnit.Case, async: true

  alias FlameOn.Client.NativeProcessor

  describe "target/0" do
    test "returns a string with arch-os format" do
      target = NativeProcessor.target()
      assert is_binary(target)
      assert String.contains?(target, "-")
    end

    test "detects a known architecture" do
      target = NativeProcessor.target()
      arch = target |> String.split("-") |> List.first()
      assert arch in ["aarch64", "x86_64", "unknown"]
    end

    test "detects a known OS" do
      target = NativeProcessor.target()
      os = target |> String.split("-") |> List.last()
      assert os in ["macos", "linux", "unknown"]
    end
  end

  describe "nif_path/0" do
    test "returns a path ending with the NIF name" do
      path = NativeProcessor.nif_path()
      assert is_binary(path)
      assert String.ends_with?(path, "libflame_on_processor_nif")
    end

    test "includes native directory in path" do
      path = NativeProcessor.nif_path()
      assert String.contains?(path, "native")
    end
  end

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

  describe "ensure_precompiled/0" do
    test "does not crash on unsupported platforms" do
      # ensure_precompiled should gracefully return true or false
      result = NativeProcessor.ensure_precompiled()
      assert is_boolean(result)
    end
  end
end
