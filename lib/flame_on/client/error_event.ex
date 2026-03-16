defmodule FlameOn.Client.ErrorEvent do
  @moduledoc false

  def build_exception_event(exception, opts \\ []) do
    stacktrace = Keyword.get(opts, :stacktrace, [])

    base_event(opts)
    |> Map.put(:message, Exception.message(exception))
    |> Map.put(:exceptions, [build_exception(exception, stacktrace)])
    |> then(&struct!(FlameOn.ErrorEvent, &1))
    |> FlameOn.Client.ErrorSanitizer.sanitize(opts)
  end

  def build_message_event(message, opts \\ []) do
    base_event(opts)
    |> Map.put(:message, to_string(message))
    |> Map.put(:exceptions, [])
    |> then(&struct!(FlameOn.ErrorEvent, &1))
    |> FlameOn.Client.ErrorSanitizer.sanitize(opts)
  end

  defp base_event(opts) do
    %{
      event_id: generate_event_id(),
      occurred_at: timestamp_now(),
      platform: "elixir",
      environment: normalize_string(Keyword.get(opts, :environment, "production")),
      service: normalize_string(Keyword.get(opts, :service, "unknown")),
      route:
        normalize_string(Keyword.get(opts, :route, request_route(Keyword.get(opts, :request)))),
      release: normalize_string(Keyword.get(opts, :release, "unknown")),
      severity: normalize_string(Keyword.get(opts, :severity, "error")),
      message: "",
      handled: Keyword.get(opts, :handled, true),
      trace_id: normalize_string(Keyword.get(opts, :trace_id, "")),
      span_id: normalize_string(Keyword.get(opts, :span_id, "")),
      fingerprint: normalize_list(Keyword.get(opts, :fingerprint, [])),
      exceptions: [],
      request: build_request(Keyword.get(opts, :request)),
      user: build_user(Keyword.get(opts, :user)),
      breadcrumbs: build_breadcrumbs(Keyword.get(opts, :breadcrumbs, [])),
      tags: build_key_values(Keyword.get(opts, :tags, %{})),
      contexts: build_key_values(Keyword.get(opts, :contexts, %{}))
    }
  end

  defp build_exception(exception, stacktrace) do
    %FlameOn.Exception{
      type: exception.__struct__ |> Module.split() |> Enum.join("."),
      value: Exception.message(exception),
      stack_trace: %FlameOn.StackTrace{frames: Enum.map(stacktrace, &build_frame/1)}
    }
  end

  defp build_frame({module, function, arity, location}) when is_list(location) do
    %FlameOn.StackFrame{
      module: inspect(module),
      function: format_function(function, arity),
      file: normalize_string(to_string(Keyword.get(location, :file, ""))),
      line: Keyword.get(location, :line, 0),
      in_app: app_frame?(module)
    }
  end

  defp build_frame(other) do
    %FlameOn.StackFrame{function: inspect(other)}
  end

  defp build_request(nil), do: nil

  defp build_request(request) do
    %FlameOn.RequestContext{
      method: normalize_string(Map.get(request, :method) || Map.get(request, "method")),
      url: normalize_string(Map.get(request, :url) || Map.get(request, "url")),
      route: normalize_string(Map.get(request, :route) || Map.get(request, "route")),
      headers: build_key_values(Map.get(request, :headers) || Map.get(request, "headers") || %{}),
      remote_addr:
        normalize_string(Map.get(request, :remote_addr) || Map.get(request, "remote_addr"))
    }
  end

  defp build_user(nil), do: nil

  defp build_user(user) do
    %FlameOn.UserContext{
      id: normalize_string(Map.get(user, :id) || Map.get(user, "id")),
      email: normalize_string(Map.get(user, :email) || Map.get(user, "email")),
      username: normalize_string(Map.get(user, :username) || Map.get(user, "username")),
      ip_address: normalize_string(Map.get(user, :ip_address) || Map.get(user, "ip_address"))
    }
  end

  defp build_breadcrumbs(breadcrumbs) do
    Enum.map(breadcrumbs, fn crumb ->
      %FlameOn.Breadcrumb{
        timestamp: timestamp_now(),
        category: normalize_string(Map.get(crumb, :category) || Map.get(crumb, "category")),
        message: normalize_string(Map.get(crumb, :message) || Map.get(crumb, "message")),
        type: normalize_string(Map.get(crumb, :type) || Map.get(crumb, "type") || "default"),
        level: normalize_string(Map.get(crumb, :level) || Map.get(crumb, "level") || "info"),
        data: build_key_values(Map.get(crumb, :data) || Map.get(crumb, "data") || %{})
      }
    end)
  end

  defp build_key_values(values) when is_map(values) do
    Enum.map(values, fn {key, value} ->
      %FlameOn.KeyValue{key: to_string(key), value: normalize_value(value)}
    end)
  end

  defp build_key_values(values) when is_list(values) do
    Enum.map(values, fn
      %FlameOn.KeyValue{} = value -> value
      {key, value} -> %FlameOn.KeyValue{key: to_string(key), value: normalize_value(value)}
    end)
  end

  defp build_key_values(_), do: []

  defp request_route(nil), do: ""
  defp request_route(request), do: Map.get(request, :route) || Map.get(request, "route") || ""

  defp format_function(function, arity) when is_integer(arity), do: "#{function}/#{arity}"
  defp format_function(function, args), do: "#{function}/#{length(args)}"

  defp app_frame?(module) do
    module
    |> inspect()
    |> String.starts_with?("Elixir.")
  end

  defp normalize_string(nil), do: ""
  defp normalize_string(value), do: to_string(value)

  defp normalize_value(value) when is_binary(value), do: value
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value) when is_number(value), do: to_string(value)
  defp normalize_value(nil), do: ""
  defp normalize_value(value), do: inspect(value)

  defp normalize_list(list), do: Enum.map(list, &to_string/1)

  defp timestamp_now do
    unix = DateTime.utc_now() |> DateTime.to_unix(:microsecond)
    %Google.Protobuf.Timestamp{seconds: div(unix, 1_000_000), nanos: rem(unix, 1_000_000) * 1_000}
  end

  defp generate_event_id do
    <<a1::32, a2::16, a3::16, a4::16, a5::48>> = :crypto.strong_rand_bytes(16)

    [a1, a2, a3, a4, a5]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map(fn {value, width} ->
      value |> Integer.to_string(16) |> String.pad_leading(width, "0")
    end)
    |> Enum.join("-")
  end
end
