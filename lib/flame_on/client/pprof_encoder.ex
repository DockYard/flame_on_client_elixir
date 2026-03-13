defmodule FlameOn.Client.PprofEncoder do
  @moduledoc """
  Encodes collapsed stack traces into pprof Profile protos wrapped in TraceProfile.

  Input: trace map with %{trace_id, event_name, event_identifier, captured_at, samples}
  where samples are [%{stack_path: "A;B;C", duration_us: N}]

  Output: %Flameon.TraceProfile{} with a fully built pprof Profile
  """

  def encode(trace) do
    profile = build_profile(trace.samples)

    %Flameon.TraceProfile{
      trace_id: trace.trace_id,
      event_name: trace.event_name,
      event_identifier: trace.event_identifier,
      profile: profile
    }
  end

  defp build_profile(samples) do
    # Collect all unique function names across all samples
    all_frames =
      samples
      |> Enum.flat_map(fn %{stack_path: path} -> String.split(path, ";") end)
      |> Enum.uniq()

    # Build string table: index 0 = "", then value type names, then all function names
    string_table_list = ["", "self_us", "total_us", "microseconds" | all_frames]
    string_index = string_table_list |> Enum.with_index() |> Map.new()

    # Build sample_type — two entries matching the two values per sample
    sample_type = [
      %Perftools.Profiles.ValueType{
        type: Map.fetch!(string_index, "self_us"),
        unit: Map.fetch!(string_index, "microseconds")
      },
      %Perftools.Profiles.ValueType{
        type: Map.fetch!(string_index, "total_us"),
        unit: Map.fetch!(string_index, "microseconds")
      }
    ]

    # Build functions: one per unique frame, IDs starting at 1
    {functions, frame_to_func_id} =
      all_frames
      |> Enum.with_index(1)
      |> Enum.map_reduce(%{}, fn {frame, id}, acc ->
        func = %Perftools.Profiles.Function{
          id: id,
          name: Map.fetch!(string_index, frame),
          system_name: Map.fetch!(string_index, frame),
          filename: 0,
          start_line: 0
        }

        {func, Map.put(acc, frame, id)}
      end)

    # Build locations: one per function, IDs starting at 1
    locations =
      Enum.map(functions, fn func ->
        %Perftools.Profiles.Location{
          id: func.id,
          line: [%Perftools.Profiles.Line{function_id: func.id, line: 0}]
        }
      end)

    # Build samples
    proto_samples =
      Enum.map(samples, fn %{stack_path: path, duration_us: duration_us} ->
        frames = String.split(path, ";")

        # pprof convention: location_ids are leaf-first (innermost frame first).
        # The server reverses these back to root-first when building call trees.
        location_ids =
          frames
          |> Enum.map(fn frame -> Map.fetch!(frame_to_func_id, frame) end)
          |> Enum.reverse()

        # Each collapsed-stack entry represents a leaf's self-time, so
        # self_us == total_us. The server aggregates total_us up the tree.
        %Perftools.Profiles.Sample{
          location_id: location_ids,
          value: [duration_us, duration_us]
        }
      end)

    %Perftools.Profiles.Profile{
      string_table: string_table_list,
      sample_type: sample_type,
      function: functions,
      location: locations,
      sample: proto_samples,
      duration_nanos: compute_duration_nanos(samples)
    }
  end

  defp compute_duration_nanos(samples) do
    case samples do
      [] -> 0
      _ -> Enum.max_by(samples, & &1.duration_us).duration_us * 1000
    end
  end
end
