defmodule FlameOn.Client.ErrorShipper do
  use GenServer

  require Logger

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def push(pid, error_event) do
    GenServer.cast(pid, {:push, error_event})
  end

  def buffer_size(pid) do
    GenServer.call(pid, :buffer_size)
  end

  @impl true
  def init(opts) do
    config = build_config(opts)
    schedule_flush(config.flush_interval_ms)

    {:ok, %{buffer: :queue.new(), buffer_length: 0, config: config}}
  end

  @impl true
  def handle_cast({:push, error_event}, state) do
    state = enqueue(state, error_event)

    if state.buffer_length >= state.config.max_batch_size do
      {:noreply, flush(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:buffer_size, _from, state) do
    {:reply, state.buffer_length, state}
  end

  @impl true
  def handle_info(:flush, state) do
    schedule_flush(state.config.flush_interval_ms)

    if state.buffer_length > 0 do
      {:noreply, flush(state)}
    else
      {:noreply, state}
    end
  end

  defp flush(state) do
    batch = :queue.to_list(state.buffer)

    Logger.info("[FlameOn] Shipping #{length(batch)} error event(s)")

    case state.config.shipper_adapter.send_batch(batch, state.config) do
      :ok -> :ok
      {:error, reason} -> Logger.error("[FlameOn] Failed to ship errors: #{inspect(reason)}")
    end

    %{state | buffer: :queue.new(), buffer_length: 0}
  end

  defp enqueue(state, item) do
    buffer = :queue.in(item, state.buffer)
    length = state.buffer_length + 1

    if length > state.config.max_buffer_size do
      {{:value, _dropped}, buffer} = :queue.out(buffer)
      %{state | buffer: buffer, buffer_length: length - 1}
    else
      %{state | buffer: buffer, buffer_length: length}
    end
  end

  defp schedule_flush(interval_ms) do
    Process.send_after(self(), :flush, interval_ms)
  end

  defp build_config(opts) do
    defaults = %{
      shipper_adapter:
        Application.get_env(
          :flame_on_client,
          :error_shipper_adapter,
          FlameOn.Client.ErrorShipper.Grpc
        ),
      server_url: FlameOn.Client.env_or_config(:server_url, "flameon.ai"),
      use_ssl: FlameOn.Client.env_or_config_bool(:use_ssl, true),
      api_key: FlameOn.Client.env_or_config(:api_key, nil),
      flush_interval_ms: Application.get_env(:flame_on_client, :error_flush_interval_ms, 5_000),
      max_batch_size: Application.get_env(:flame_on_client, :max_error_batch_size, 50),
      max_buffer_size: Application.get_env(:flame_on_client, :max_error_buffer_size, 500),
      environment: Application.get_env(:flame_on_client, :environment, "production"),
      service: Application.get_env(:flame_on_client, :service, "unknown"),
      release: Application.get_env(:flame_on_client, :release, "unknown")
    }

    Map.merge(defaults, Map.new(opts))
  end
end
