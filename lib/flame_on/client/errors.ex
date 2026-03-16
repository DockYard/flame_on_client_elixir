defmodule FlameOn.Client.Errors do
  alias FlameOn.Client.ErrorEvent
  alias FlameOn.Client.ErrorContext
  alias FlameOn.Client.ErrorDedupe
  alias FlameOn.Client.ErrorShipper
  alias FlameOn.Client.Errors.Config
  alias FlameOn.Client.TraceContext

  def set_user(user), do: ErrorContext.set_user(user)
  def set_tags(tags), do: ErrorContext.set_tags(tags)
  def set_context(key, value), do: ErrorContext.set_context(key, value)
  def add_breadcrumb(breadcrumb), do: ErrorContext.add_breadcrumb(breadcrumb)
  def clear_context, do: ErrorContext.clear()

  def capture_exception(exception, opts \\ []) do
    config = Config.config()

    event =
      ErrorEvent.build_exception_event(
        exception,
        merged_opts(config, opts)
      )

    dispatch(event)
  end

  def capture_message(message, opts \\ []) do
    config = Config.config()

    event =
      ErrorEvent.build_message_event(message, merged_opts(config, opts))

    dispatch(event)
  end

  defp dispatch(event) do
    event = apply_before_send(event)

    if is_nil(event) do
      return_ok()
    else
      if ErrorDedupe.duplicate?(event, Config.dedupe_window_ms()) do
        :ok
      else
        case Process.whereis(FlameOn.Client.ErrorShipper) do
          nil -> :ok
          pid -> ErrorShipper.push(pid, event)
        end

        :ok
      end
    end
  end

  defp apply_before_send(event) do
    case Application.get_env(:flame_on_client, :before_send) do
      nil -> event
      fun when is_function(fun, 1) -> fun.(event)
    end
  end

  defp return_ok do
    :ok
  end

  defp merged_opts(config, opts) do
    context = ErrorContext.current()
    opts_map = Map.new(opts)

    config
    |> Map.put_new(:trace_id, TraceContext.current_trace_id() || "")
    |> Map.put(:user, Map.get(opts_map, :user, context.user))
    |> Map.put(:tags, Map.merge(context.tags, Map.get(opts_map, :tags, %{})))
    |> Map.put(:contexts, Map.merge(context.contexts, Map.get(opts_map, :contexts, %{})))
    |> Map.put(:breadcrumbs, context.breadcrumbs ++ Map.get(opts_map, :breadcrumbs, []))
    |> Map.merge(opts_map)
    |> Map.to_list()
  end
end

defmodule FlameOn.Client.Errors.Config do
  @moduledoc false

  def config do
    %{
      environment: Application.get_env(:flame_on_client, :environment, "production"),
      service: Application.get_env(:flame_on_client, :service, "unknown"),
      release: Application.get_env(:flame_on_client, :release, "unknown"),
      max_string_length: Application.get_env(:flame_on_client, :max_string_length, 2_000),
      max_breadcrumbs: Application.get_env(:flame_on_client, :max_breadcrumbs, 50)
    }
  end

  def dedupe_window_ms do
    Application.get_env(:flame_on_client, :error_dedupe_window_ms, 5_000)
  end
end
