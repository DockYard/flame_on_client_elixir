defmodule FlameOn.Client.ErrorContext do
  @moduledoc false

  @key {__MODULE__, :context}

  def current do
    Process.get(@key, %{user: nil, tags: %{}, contexts: %{}, breadcrumbs: []})
  end

  def set_user(user) do
    update(fn state -> %{state | user: user} end)
  end

  def set_tags(tags) when is_map(tags) do
    update(fn state -> %{state | tags: Map.merge(state.tags, tags)} end)
  end

  def set_context(key, value) do
    update(fn state -> %{state | contexts: Map.put(state.contexts, key, value)} end)
  end

  def add_breadcrumb(breadcrumb) do
    update(fn state -> %{state | breadcrumbs: state.breadcrumbs ++ [breadcrumb]} end)
  end

  def clear do
    Process.delete(@key)
    :ok
  end

  defp update(fun) do
    state = current() |> fun.()
    Process.put(@key, state)
    :ok
  end
end
