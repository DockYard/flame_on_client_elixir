defmodule FlameOn.Client do
  def config do
    %{
      capture: Application.get_env(:flame_on_client, :capture),
      ingest_token: Application.get_env(:flame_on_client, :ingest_token),
      event_handler: Application.get_env(:flame_on_client, :event_handler),
      sample_rate: Application.get_env(:flame_on_client, :sample_rate),
      function_length_threshold: Application.get_env(:flame_on_client, :function_length_threshold),
      flush_interval_ms: Application.get_env(:flame_on_client, :flush_interval_ms),
      max_batch_size: Application.get_env(:flame_on_client, :max_batch_size),
      max_buffer_size: Application.get_env(:flame_on_client, :max_buffer_size),
      events: Application.get_env(:flame_on_client, :events)
    }
  end

  def active_traces do
    FlameOn.Client.Collector.active_trace_count(FlameOn.Client.Collector)
  end

  @doc false
  def env_or_config(key, default) do
    env_key = "FLAME_ON_#{key |> Atom.to_string() |> String.upcase()}"

    with nil <- System.get_env(env_key),
         val when val in [nil, ""] <- Application.get_env(:flame_on_client, key) do
      default
    else
      value -> value
    end
  end

  @doc false
  def env_or_config_bool(key, default) do
    env_key = "FLAME_ON_#{key |> Atom.to_string() |> String.upcase()}"

    case System.get_env(env_key) do
      nil ->
        case Application.get_env(:flame_on_client, key) do
          nil -> default
          value -> value
        end

      value ->
        value in ["true", "1"]
    end
  end
end
