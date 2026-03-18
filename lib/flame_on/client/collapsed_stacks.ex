defmodule FlameOn.Client.CollapsedStacks do
  alias FlameOn.Client.Capture.Block

  def convert(%Block{} = root) do
    walk(root, [])
    |> List.flatten()
  end

  defp walk(%Block{children: [], function: function, duration: duration}, ancestors) do
    path = build_path(ancestors ++ [function])
    [%{stack_path: path, duration_us: duration}]
  end

  defp walk(%Block{children: children, function: function, duration: duration}, ancestors) do
    current_path = ancestors ++ [function]

    child_entries =
      Enum.flat_map(children, fn child ->
        walk(child, current_path)
      end)

    children_duration = Enum.sum(Enum.map(children, & &1.duration))
    self_time = duration - children_duration

    if self_time > 0 do
      self_entry = %{stack_path: build_path(current_path), duration_us: self_time}
      [self_entry | child_entries]
    else
      child_entries
    end
  end

  defp build_path(functions) do
    functions
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
