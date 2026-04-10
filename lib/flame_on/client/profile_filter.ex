defmodule FlameOn.Client.ProfileFilter do
  @default_function_length_threshold 0.01
  @min_function_length_threshold 0.005

  def filter(samples, opts \\ [])
  def filter([], _opts), do: []

  def filter(samples, opts) do
    threshold_pct =
      opts
      |> Keyword.get(:function_length_threshold, @default_function_length_threshold)
      |> max(@min_function_length_threshold)
    total_time = Enum.sum(Enum.map(samples, & &1.duration_us))

    if total_time == 0 do
      samples
    else
      threshold_us = total_time * threshold_pct
      inclusive_times = build_inclusive_times(samples)

      small_blocks =
        inclusive_times
        |> Enum.filter(fn {_path, time} -> time < threshold_us end)
        |> Enum.map(fn {path, _time} -> path end)
        |> MapSet.new()

      if MapSet.size(small_blocks) == 0 do
        samples
      else
        consolidate(samples, small_blocks, inclusive_times)
      end
    end
  end

  defp build_inclusive_times(samples) do
    Enum.reduce(samples, %{}, fn %{stack_path: path, duration_us: duration}, acc ->
      path
      |> path_prefixes()
      |> Enum.reduce(acc, fn prefix, inner_acc ->
        Map.update(inner_acc, prefix, duration, &(&1 + duration))
      end)
    end)
  end

  defp path_prefixes(path) do
    positions = :binary.matches(path, ";")
    prefix_list = Enum.map(positions, fn {pos, _len} -> binary_part(path, 0, pos) end)
    prefix_list ++ [path]
  end

  defp consolidate(samples, small_blocks, inclusive_times) do
    # Keep samples that don't have a small ancestor
    kept =
      Enum.reject(samples, fn %{stack_path: path} ->
        has_small_ancestor?(path, small_blocks) or MapSet.member?(small_blocks, path)
      end)

    # Add consolidated entries for small blocks that aren't children of other small blocks
    consolidated =
      small_blocks
      |> Enum.reject(fn block_path -> has_small_ancestor?(block_path, small_blocks) end)
      |> Enum.map(fn block_path ->
        %{stack_path: block_path, duration_us: Map.fetch!(inclusive_times, block_path)}
      end)

    kept ++ consolidated
  end

  defp has_small_ancestor?(path, small_blocks) do
    prefixes = path_prefixes(path)
    # Proper prefixes = all except the last (which is the path itself)
    proper_prefixes = Enum.slice(prefixes, 0..-2//1)
    Enum.any?(proper_prefixes, fn prefix -> MapSet.member?(small_blocks, prefix) end)
  end
end
