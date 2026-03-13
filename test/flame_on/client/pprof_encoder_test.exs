defmodule FlameOn.Client.PprofEncoderTest do
  use ExUnit.Case, async: true

  alias FlameOn.Client.PprofEncoder

  defp build_trace(overrides \\ %{}) do
    defaults = %{
      trace_id: "trace-123",
      event_name: "web.request",
      event_identifier: "GET /users",
      captured_at: 1_709_500_000_000_000,
      samples: [
        %{stack_path: "Elixir.MyApp.Router.call/2;Elixir.MyApp.Repo.all/1", duration_us: 500},
        %{stack_path: "Elixir.MyApp.Router.call/2", duration_us: 100}
      ]
    }

    Map.merge(defaults, overrides)
  end

  describe "encode/1" do
    test "returns a TraceProfile with correct metadata" do
      trace = build_trace()
      result = PprofEncoder.encode(trace)

      assert %Flameon.TraceProfile{} = result
      assert result.trace_id == "trace-123"
      assert result.event_name == "web.request"
      assert result.event_identifier == "GET /users"
    end

    test "builds a valid pprof Profile" do
      trace = build_trace()
      result = PprofEncoder.encode(trace)
      profile = result.profile

      assert %Perftools.Profiles.Profile{} = profile
      # string_table[0] must be ""
      assert hd(profile.string_table) == ""
      assert length(profile.function) > 0
      assert length(profile.location) > 0
      assert length(profile.sample) > 0
    end

    test "deduplicates string table entries" do
      trace = build_trace(%{
        samples: [
          %{stack_path: "A;B;C", duration_us: 100},
          %{stack_path: "A;B;D", duration_us: 200}
        ]
      })

      result = PprofEncoder.encode(trace)
      profile = result.profile

      # "A" and "B" appear in both samples but should only appear once in string_table
      a_count = Enum.count(profile.string_table, &(&1 == "A"))
      assert a_count == 1

      b_count = Enum.count(profile.string_table, &(&1 == "B"))
      assert b_count == 1
    end

    test "creates one function per unique frame" do
      trace = build_trace(%{
        samples: [
          %{stack_path: "A;B", duration_us: 100},
          %{stack_path: "A;C", duration_us: 200}
        ]
      })

      result = PprofEncoder.encode(trace)
      profile = result.profile

      # 3 unique frames: A, B, C
      assert length(profile.function) == 3
    end

    test "creates one location per unique frame" do
      trace = build_trace(%{
        samples: [
          %{stack_path: "A;B", duration_us: 100},
          %{stack_path: "A;C", duration_us: 200}
        ]
      })

      result = PprofEncoder.encode(trace)
      profile = result.profile

      assert length(profile.location) == 3
    end

    test "samples reference correct location IDs" do
      trace = build_trace(%{
        samples: [
          %{stack_path: "A;B", duration_us: 100}
        ]
      })

      result = PprofEncoder.encode(trace)
      profile = result.profile
      [sample] = profile.sample

      # Sample should have 2 location IDs (for A and B)
      assert length(sample.location_id) == 2
      # Location IDs should reference actual locations
      loc_ids = Enum.map(profile.location, & &1.id)
      for loc_id <- sample.location_id, do: assert(loc_id in loc_ids)
    end

    test "sample values encode self_us and total_us" do
      trace = build_trace(%{
        samples: [
          %{stack_path: "A;B", duration_us: 500}
        ]
      })

      result = PprofEncoder.encode(trace)
      [sample] = result.profile.sample

      # Collapsed-stack entries are leaf self-time, so self_us == total_us
      assert sample.value == [500, 500]
    end

    test "declares two sample_types matching the two values per sample" do
      trace = build_trace()
      result = PprofEncoder.encode(trace)
      profile = result.profile

      assert length(profile.sample_type) == 2

      string_table = List.to_tuple(profile.string_table)
      [self_type, total_type] = profile.sample_type

      assert elem(string_table, self_type.type) == "self_us"
      assert elem(string_table, self_type.unit) == "microseconds"
      assert elem(string_table, total_type.type) == "total_us"
      assert elem(string_table, total_type.unit) == "microseconds"
    end

    test "location_ids follow pprof convention (leaf-first / innermost-first)" do
      trace = build_trace(%{
        samples: [
          %{stack_path: "root;middle;leaf", duration_us: 100}
        ]
      })

      result = PprofEncoder.encode(trace)
      profile = result.profile
      [sample] = profile.sample

      # Resolve location_ids back to function names via location → function → string_table
      string_table = List.to_tuple(profile.string_table)
      func_map = Map.new(profile.function, fn f -> {f.id, elem(string_table, f.name)} end)
      loc_map = Map.new(profile.location, fn l -> {l.id, hd(l.line).function_id} end)

      names =
        Enum.map(sample.location_id, fn loc_id ->
          func_id = Map.fetch!(loc_map, loc_id)
          Map.fetch!(func_map, func_id)
        end)

      # pprof convention: innermost (leaf) first, outermost (root) last
      assert names == ["leaf", "middle", "root"]
    end

    test "handles empty samples list" do
      trace = build_trace(%{samples: []})
      result = PprofEncoder.encode(trace)

      assert result.profile.function == []
      assert result.profile.location == []
      assert result.profile.sample == []
    end
  end
end
