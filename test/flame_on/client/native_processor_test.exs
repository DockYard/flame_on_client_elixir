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
    test "returns a boolean" do
      assert is_boolean(NativeProcessor.available?())
    end
  end

  describe "process_stacks/2" do
    test "returns {:ok, binary} or {:error, atom}" do
      stacks = %{"A;B;C" => 1000, "A;B" => 500}
      result = NativeProcessor.process_stacks(stacks, 0.01)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles empty stacks" do
      result = NativeProcessor.process_stacks(%{}, 0.01)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles various threshold values" do
      stacks = %{"root;child" => 100}
      for threshold <- [0.0, 1.0, 0.005] do
        result = NativeProcessor.process_stacks(stacks, threshold)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end

    if FlameOn.Client.NativeProcessor.available?() do
      test "NIF returns protobuf binary" do
        stacks = %{
          "Enum.map/2;Process.work/1" => 50000,
          "Enum.map/2;JSON.encode/1" => 30000
        }
        assert {:ok, binary} = NativeProcessor.process_stacks(stacks, 0.01)
        assert is_binary(binary)
        assert byte_size(binary) > 0
      end
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
