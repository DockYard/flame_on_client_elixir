defmodule FlameOn.Client.EventHandler.Default do
  @behaviour FlameOn.Client.EventHandler

  @default_thresholds %{
    [:phoenix, :router_dispatch, :start] => 500,
    [:oban, :job, :start] => 30_000,
    [:phoenix, :live_view, :handle_event, :start] => 200,
    [:phoenix, :live_component, :handle_event, :start] => 200,
    [:absinthe, :execute, :operation, :start] => 1_000
  }
  @global_default_threshold_ms 100

  @impl true
  def default_threshold_ms(event),
    do: Map.get(@default_thresholds, event, @global_default_threshold_ms)

  @impl true
  def handle([:phoenix, :router_dispatch, :start], _measurements, %{conn: conn}) do
    route = phoenix_route_pattern(conn)
    identifier = "#{conn.method} #{route}"

    {:capture,
     %{
       event_name: "phoenix.request",
       event_identifier: identifier,
     }}
  end

  def handle([:oban, :job, :start], _measurements, %{job: job}) do
    identifier = inspect(job.worker)

    {:capture,
     %{
       event_name: "oban.job",
       event_identifier: identifier,
     }}
  end

  def handle([:phoenix, :live_view, :handle_event, :start], _measurements, %{
        socket: socket,
        event: event
      }) do
    identifier = "#{inspect(socket.view)}.#{event}"

    {:capture,
     %{
       event_name: "live_view.event",
       event_identifier: identifier,
     }}
  end

  def handle([:phoenix, :live_component, :handle_event, :start], _measurements, %{
        component: component,
        event: event
      }) do
    identifier = "#{inspect(component)}.#{event}"

    {:capture,
     %{
       event_name: "live_component.event",
       event_identifier: identifier,
     }}
  end

  def handle([:absinthe, :execute, :operation, :start], _measurements, %{options: options}) do
    op_name = get_in(options, [:document, :name]) || "anonymous"

    {:capture,
     %{
       event_name: "graphql.operation",
       event_identifier: op_name,
     }}
  end

  def handle(_event, _measurements, _metadata), do: :skip

  defp phoenix_route_pattern(conn) do
    case conn.private do
      %{phoenix_route: route} -> route
      %{plug_route: {route, _}} -> route
      _ -> conn.request_path
    end
  end
end
