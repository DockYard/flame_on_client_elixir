defmodule FlameOn.Client.TraceSessionSupervisor do
  use DynamicSupervisor

  def start_link(opts) do
    {name, _opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    DynamicSupervisor.start_link(__MODULE__, [], gen_opts)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_session(supervisor, opts) do
    DynamicSupervisor.start_child(supervisor, {FlameOn.Client.TraceSession, opts})
  end
end
