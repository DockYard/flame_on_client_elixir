defmodule FlameOn.Client.LiveViewReporter do
  @moduledoc false

  alias FlameOn.Client.Errors

  def capture_exception(socket, event_name, exception, stacktrace, opts \\ []) do
    Errors.capture_exception(
      exception,
      Keyword.merge(
        [
          stacktrace: stacktrace,
          handled: false,
          route: "live_view.event",
          user: current_user(socket),
          tags: %{
            view: inspect(Map.get(socket, :view) || get_in(socket, [:assigns, :live_module])),
            event: to_string(event_name)
          },
          breadcrumbs: [%{category: "live_view", message: to_string(event_name), level: "error"}]
        ],
        opts
      )
    )
  end

  defp current_user(socket) do
    assigns = Map.get(socket, :assigns, %{})
    Map.get(assigns, :current_user) || Map.get(assigns, "current_user")
  end
end
