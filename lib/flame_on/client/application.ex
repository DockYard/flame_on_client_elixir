defmodule FlameOn.Client.Application do
  use Application

  @impl true
  def start(_type, _args) do
    maybe_attach_logger_fallback()

    children =
      []
      |> maybe_add_grpc_supervisor()
      |> maybe_add_trace_children()
      |> maybe_add_error_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: FlameOn.Client.Supervisor)
  end

  @impl true
  def stop(_state) do
    FlameOn.Client.LoggerReporter.detach()
    :ok
  end

  defp maybe_add_grpc_supervisor(children) do
    if Application.get_env(:flame_on_client, :capture, false) or
         Application.get_env(:flame_on_client, :capture_errors, false) do
      [{DynamicSupervisor, strategy: :one_for_one, name: GRPC.Client.Supervisor} | children]
    else
      children
    end
  end

  defp maybe_add_trace_children(children) do
    if Application.get_env(:flame_on_client, :capture, false) do
      children ++
        [
          {FlameOn.Client.SeqTraceRouter, name: FlameOn.Client.SeqTraceRouter},
          {FlameOn.Client.Shipper, name: FlameOn.Client.Shipper},
          {FlameOn.Client.TraceSessionSupervisor, name: FlameOn.Client.TraceSessionSupervisor},
          {FlameOn.Client.Collector, name: FlameOn.Client.Collector}
        ]
    else
      children
    end
  end

  defp maybe_add_error_children(children) do
    if Application.get_env(:flame_on_client, :capture_errors, false) do
      children ++ [{FlameOn.Client.ErrorShipper, name: FlameOn.Client.ErrorShipper}]
    else
      children
    end
  end

  defp maybe_attach_logger_fallback do
    if Application.get_env(:flame_on_client, :capture_errors, false) and
         Application.get_env(:flame_on_client, :logger_fallback, false) do
      FlameOn.Client.LoggerReporter.attach()
    else
      :ok
    end
  end
end
