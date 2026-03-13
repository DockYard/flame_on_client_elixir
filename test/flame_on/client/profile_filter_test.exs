defmodule FlameOn.Client.ProfileFilterTest do
  use ExUnit.Case, async: true

  alias FlameOn.Client.ProfileFilter

  describe "filter/2" do
    test "returns samples unchanged when all blocks are above threshold" do
      samples = [
        %{stack_path: "A;B", duration_us: 500},
        %{stack_path: "A;C", duration_us: 500}
      ]

      assert ProfileFilter.filter(samples) == samples
    end

    test "filters children of a block below 1% and consolidates" do
      # Total = 1000. Block "A;B" inclusive = 5 (0.5%) → below threshold
      samples = [
        %{stack_path: "A;B;C", duration_us: 3},
        %{stack_path: "A;B;D", duration_us: 2},
        %{stack_path: "A;E", duration_us: 995}
      ]

      result = ProfileFilter.filter(samples)

      assert length(result) == 2
      assert %{stack_path: "A;E", duration_us: 995} in result
      # "A;B" consolidated with inclusive time
      assert %{stack_path: "A;B", duration_us: 5} in result
    end

    test "keeps block self-time entry and absorbs children when below threshold" do
      # Total = 1000. Block "A;B" inclusive = 8 (0.8%) → below threshold
      # "A;B" has self-time entry of 2 + children C=3, D=3
      samples = [
        %{stack_path: "A;B", duration_us: 2},
        %{stack_path: "A;B;C", duration_us: 3},
        %{stack_path: "A;B;D", duration_us: 3},
        %{stack_path: "A;E", duration_us: 992}
      ]

      result = ProfileFilter.filter(samples)

      assert length(result) == 2
      assert %{stack_path: "A;E", duration_us: 992} in result
      # "A;B" consolidated: 2 + 3 + 3 = 8
      assert %{stack_path: "A;B", duration_us: 8} in result
    end

    test "handles nested small blocks — child small block absorbed by parent small block" do
      # Total = 1000. "A;B" inclusive = 6 (0.6%), "A;B;C" inclusive = 4 (0.4%)
      # Both below threshold. "A;B;C" is a child of "A;B", so it gets absorbed into "A;B"
      samples = [
        %{stack_path: "A;B", duration_us: 2},
        %{stack_path: "A;B;C", duration_us: 1},
        %{stack_path: "A;B;C;D", duration_us: 3},
        %{stack_path: "A;E", duration_us: 994}
      ]

      result = ProfileFilter.filter(samples)

      assert length(result) == 2
      assert %{stack_path: "A;E", duration_us: 994} in result
      # "A;B" gets consolidated (its child "A;B;C" is also small, but absorbed into "A;B")
      assert %{stack_path: "A;B", duration_us: 6} in result
    end

    test "returns empty list for empty input" do
      assert ProfileFilter.filter([]) == []
    end

    test "returns single sample unchanged" do
      samples = [%{stack_path: "A", duration_us: 100}]
      assert ProfileFilter.filter(samples) == samples
    end

    test "accepts custom threshold" do
      # Total = 100. "A;B" inclusive = 9 (9%)
      # Default threshold (1%) would keep it. 10% threshold filters it.
      samples = [
        %{stack_path: "A;B;C", duration_us: 9},
        %{stack_path: "A;D", duration_us: 91}
      ]

      # At default 1%, "A;B" (9%) stays
      default_result = ProfileFilter.filter(samples)
      assert length(default_result) == 2

      # At 10%, "A;B" (9%) gets filtered
      filtered_result = ProfileFilter.filter(samples, function_length_threshold: 0.10)
      assert length(filtered_result) == 2
      assert %{stack_path: "A;B", duration_us: 9} in filtered_result
      assert %{stack_path: "A;D", duration_us: 91} in filtered_result
    end

    test "preserves samples when block is exactly at threshold" do
      # Total = 100. "A;B" inclusive = 1 (exactly 1%) → NOT below, should keep
      samples = [
        %{stack_path: "A;B;C", duration_us: 1},
        %{stack_path: "A;D", duration_us: 99}
      ]

      result = ProfileFilter.filter(samples)
      assert length(result) == 2
      assert %{stack_path: "A;B;C", duration_us: 1} in result
    end

    test "enforces minimum threshold of 0.5%" do
      # Total = 1000. "A;B" inclusive = 4 (0.4%) → below min threshold of 0.5%
      # Even with function_length_threshold: 0.001 (0.1%), should use 0.5% minimum
      samples = [
        %{stack_path: "A;B;C", duration_us: 4},
        %{stack_path: "A;D", duration_us: 996}
      ]

      # With threshold below minimum (0.1%), the min of 0.5% is enforced
      result = ProfileFilter.filter(samples, function_length_threshold: 0.001)
      assert length(result) == 2
      assert %{stack_path: "A;B", duration_us: 4} in result
      assert %{stack_path: "A;D", duration_us: 996} in result
    end

    test "filters multiple independent small blocks" do
      # Total = 1000. "A;B" inclusive = 3 (0.3%), "A;C" inclusive = 4 (0.4%)
      samples = [
        %{stack_path: "A;B;X", duration_us: 3},
        %{stack_path: "A;C;Y", duration_us: 4},
        %{stack_path: "A;D", duration_us: 993}
      ]

      result = ProfileFilter.filter(samples)

      assert length(result) == 3
      assert %{stack_path: "A;B", duration_us: 3} in result
      assert %{stack_path: "A;C", duration_us: 4} in result
      assert %{stack_path: "A;D", duration_us: 993} in result
    end
  end
end
