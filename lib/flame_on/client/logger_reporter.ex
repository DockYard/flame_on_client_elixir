defmodule FlameOn.Client.LoggerReporter do
  @moduledoc false

  alias FlameOn.Client.Errors

  @handler_id __MODULE__
  @levels [:error, :critical, :alert, :emergency]

  def attach do
    :logger.add_handler(@handler_id, FlameOn.Client.LoggerHandler, %{})
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def detach do
    :logger.remove_handler(@handler_id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def capture_log_event(%{level: level} = event) when level in @levels do
    message = format_message(event)

    cond do
      message == "" ->
        :ok

      String.contains?(message, "[FlameOn]") ->
        :ok

      true ->
        Errors.capture_message(message,
          handled: false,
          route: "logger.error",
          severity: Atom.to_string(level),
          tags: %{logger_source: "fallback", level: Atom.to_string(level)},
          contexts: logger_context(event)
        )
    end
  end

  def capture_log_event(_event), do: :ok

  defp format_message(%{msg: {:string, message}}), do: IO.iodata_to_binary(message)

  defp format_message(%{msg: {format, args}}) when is_binary(format),
    do: :io_lib.format(format, args) |> IO.iodata_to_binary()

  defp format_message(%{msg: message}) when is_binary(message), do: message
  defp format_message(%{msg: message}), do: inspect(message)

  defp logger_context(event) do
    meta = Map.get(event, :meta, %{})

    %{}
    |> maybe_put(:mfa, format_mfa(meta[:mfa]))
    |> maybe_put(:file, meta[:file])
    |> maybe_put(:line, meta[:line])
    |> maybe_put(:domain, meta[:domain])
  end

  defp format_mfa(nil), do: nil
  defp format_mfa({module, function, arity}), do: "#{inspect(module)}.#{function}/#{arity}"
  defp format_mfa(other), do: inspect(other)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule FlameOn.Client.LoggerHandler do
  @moduledoc false

  def adding_handler(config), do: {:ok, config}
  def removing_handler(_config), do: :ok
  def changing_config(_set_or_update, config1, _config2), do: {:ok, config1}

  def log(event, config) do
    _ = FlameOn.Client.LoggerReporter.capture_log_event(event)
    {:ok, config}
  end
end
