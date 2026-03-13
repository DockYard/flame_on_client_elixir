defmodule FlameOn.Client.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:flame_on_client, :capture, false) do
        [
          {DynamicSupervisor, strategy: :one_for_one, name: GRPC.Client.Supervisor},
          {FlameOn.Client.Shipper, name: FlameOn.Client.Shipper},
          {FlameOn.Client.Collector, name: FlameOn.Client.Collector}
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: FlameOn.Client.Supervisor)
  end
end
