defmodule FlameOn.Client.CollapsedStacks do
  alias FlameOn.Client.Capture.Block

  def convert(%Block{} = root) do
    walk(root, [])
    |> List.flatten()
  end

  defp walk(%Block{children: [], function: function, duration: duration}, ancestors_reversed) do
    path = build_path_from_reversed([function | ancestors_reversed])
    [%{stack_path: path, duration_us: duration}]
  end

  defp walk(%Block{children: children, function: function, duration: duration}, ancestors_reversed) do
    new_ancestors = [function | ancestors_reversed]

    child_entries =
      Enum.flat_map(children, fn child ->
        walk(child, new_ancestors)
      end)

    children_duration = Enum.sum(Enum.map(children, & &1.duration))
    self_time = duration - children_duration

    if self_time > 0 do
      self_entry = %{stack_path: build_path_from_reversed(new_ancestors), duration_us: self_time}
      [self_entry | child_entries]
    else
      child_entries
    end
  end

  defp build_path_from_reversed(reversed_list) do
    reversed_list
    |> Enum.reverse()
    |> Enum.map(&format_function/1)
    |> Enum.join(";")
  end

  def format_function(:sleep), do: "SLEEP"

  def format_function({:cross_process_call, _pid, name}) do
    "CALL #{format_process_name(name)}"
  end

  def format_function({:cross_process_call, _pid, name, message_form}) do
    "CALL #{format_process_name(name)} #{format_message_form(message_form)}"
  end

  def format_function({:root, event_name, event_identifier}) do
    "#{event_name} #{event_identifier}"
  end

  def format_function({module, function, arity}) do
    "#{module}.#{function}/#{arity}"
  end

  defp format_process_name(nil), do: "<process>"
  defp format_process_name(name) when is_atom(name), do: inspect(name)

  defp format_message_form(form) do
    inspect(form, charlists: :as_lists)
  end
end
