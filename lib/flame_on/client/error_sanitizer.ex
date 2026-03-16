defmodule FlameOn.Client.ErrorSanitizer do
  @moduledoc false

  @default_redact_fields ~w(authorization cookie set-cookie password passwd secret token api_key api-key)

  def sanitize(%FlameOn.ErrorEvent{} = event, opts \\ []) do
    redact_fields = redact_fields(opts)
    max_string_length = Keyword.get(opts, :max_string_length, 2_000)
    max_breadcrumbs = Keyword.get(opts, :max_breadcrumbs, 50)

    %FlameOn.ErrorEvent{
      event
      | message: truncate_string(event.message, max_string_length),
        route: truncate_string(event.route, max_string_length),
        request: sanitize_request(event.request, redact_fields, max_string_length),
        tags: sanitize_key_values(event.tags, redact_fields, max_string_length),
        contexts: sanitize_key_values(event.contexts, redact_fields, max_string_length),
        breadcrumbs:
          event.breadcrumbs
          |> Enum.take(max_breadcrumbs)
          |> Enum.map(&sanitize_breadcrumb(&1, redact_fields, max_string_length)),
        exceptions: Enum.map(event.exceptions, &sanitize_exception(&1, max_string_length))
    }
  end

  defp sanitize_request(nil, _redact_fields, _max_string_length), do: nil

  defp sanitize_request(%FlameOn.RequestContext{} = request, redact_fields, max_string_length) do
    %FlameOn.RequestContext{
      request
      | method: truncate_string(request.method, max_string_length),
        url: truncate_string(request.url, max_string_length),
        route: truncate_string(request.route, max_string_length),
        remote_addr: truncate_string(request.remote_addr, max_string_length),
        headers: sanitize_key_values(request.headers, redact_fields, max_string_length)
    }
  end

  defp sanitize_breadcrumb(%FlameOn.Breadcrumb{} = breadcrumb, redact_fields, max_string_length) do
    %FlameOn.Breadcrumb{
      breadcrumb
      | category: truncate_string(breadcrumb.category, max_string_length),
        message: truncate_string(breadcrumb.message, max_string_length),
        type: truncate_string(breadcrumb.type, max_string_length),
        level: truncate_string(breadcrumb.level, max_string_length),
        data: sanitize_key_values(breadcrumb.data, redact_fields, max_string_length)
    }
  end

  defp sanitize_exception(%FlameOn.Exception{} = exception, max_string_length) do
    %FlameOn.Exception{
      exception
      | type: truncate_string(exception.type, max_string_length),
        value: truncate_string(exception.value, max_string_length),
        stack_trace: sanitize_stack_trace(exception.stack_trace, max_string_length)
    }
  end

  defp sanitize_stack_trace(nil, _max_string_length), do: nil

  defp sanitize_stack_trace(%FlameOn.StackTrace{} = stack_trace, max_string_length) do
    %FlameOn.StackTrace{
      frames:
        Enum.map(stack_trace.frames, fn %FlameOn.StackFrame{} = frame ->
          %FlameOn.StackFrame{
            frame
            | function: truncate_string(frame.function, max_string_length),
              module: truncate_string(frame.module, max_string_length),
              file: truncate_string(frame.file, max_string_length),
              abs_path: truncate_string(frame.abs_path, max_string_length),
              context_line: truncate_string(frame.context_line, max_string_length),
              pre_context: Enum.map(frame.pre_context, &truncate_string(&1, max_string_length)),
              post_context: Enum.map(frame.post_context, &truncate_string(&1, max_string_length))
          }
        end)
    }
  end

  defp sanitize_key_values(values, redact_fields, max_string_length) do
    Enum.map(values, fn %FlameOn.KeyValue{key: key, value: value} = pair ->
      if redact_key?(key, redact_fields) do
        %FlameOn.KeyValue{pair | value: "[REDACTED]"}
      else
        %FlameOn.KeyValue{pair | value: truncate_string(value, max_string_length)}
      end
    end)
  end

  defp truncate_string(value, max_string_length) when is_binary(value) do
    String.slice(value, 0, max_string_length)
  end

  defp truncate_string(value, _max_string_length), do: value

  defp redact_key?(key, redact_fields) do
    normalized = key |> to_string() |> String.downcase()
    normalized in redact_fields
  end

  defp redact_fields(opts) do
    opts
    |> Keyword.get(:redact_fields, [])
    |> Enum.map(&(&1 |> to_string() |> String.downcase()))
    |> then(&Enum.uniq(@default_redact_fields ++ &1))
  end
end
