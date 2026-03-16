defmodule FlameOn.Client.PhoenixPlug do
  @moduledoc false

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  def call(conn, next) when is_function(next, 1) do
    try do
      next.(conn)
    rescue
      exception ->
        stacktrace = __STACKTRACE__

        FlameOn.Client.Errors.capture_exception(exception,
          stacktrace: stacktrace,
          handled: false,
          route: conn.private[:phoenix_route] || conn.request_path,
          request: request_context(conn),
          user: current_user(conn)
        )

        reraise exception, stacktrace
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__

        FlameOn.Client.Errors.capture_message(Exception.format_banner(kind, reason),
          handled: false,
          route: conn.private[:phoenix_route] || conn.request_path,
          request: request_context(conn),
          fingerprint: [to_string(kind), inspect(reason)]
        )

        :erlang.raise(kind, reason, stacktrace)
    end
  end

  @impl true
  def call(conn, _opts), do: conn

  defp request_context(conn) do
    %{
      method: conn.method,
      url: request_url(conn),
      route: conn.private[:phoenix_route] || conn.request_path,
      headers: Map.new(conn.req_headers),
      remote_addr: format_remote_ip(conn.remote_ip)
    }
  end

  defp current_user(conn) do
    case conn.assigns[:current_user] do
      nil ->
        nil

      user ->
        %{
          id: Map.get(user, :id) || Map.get(user, "id"),
          email: Map.get(user, :email) || Map.get(user, "email")
        }
    end
  end

  defp request_url(conn) do
    port =
      case conn.port do
        80 -> ""
        443 -> ""
        port when is_integer(port) -> ":#{port}"
        _ -> ""
      end

    "#{conn.scheme}://#{conn.host}#{port}#{conn.request_path}"
  end

  defp format_remote_ip({a, b, c, d}), do: Enum.join([a, b, c, d], ".")
  defp format_remote_ip(nil), do: ""
  defp format_remote_ip(other), do: to_string(:inet.ntoa(other))
end
