defmodule FlameOn.Client.Shipper do
  use GenServer

  require Logger

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def push(pid, trace_data) do
    GenServer.cast(pid, {:push, trace_data})
  end

  def buffer_size(pid) do
    GenServer.call(pid, :buffer_size)
  end

  @impl true
  def init(opts) do
    config = build_config(opts)
    schedule_flush(config.flush_interval_ms)

    {:ok,
     %{
       buffer: :queue.new(),
       buffer_length: 0,
       config: config
     }}
  end

  @impl true
  def handle_cast({:push, trace_data}, state) do
    state = enqueue(state, trace_data)

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
  def handle_info({:gun_data, _, _, _, _}, state), do: {:noreply, state}
  def handle_info({:gun_up, _, _}, state), do: {:noreply, state}
  def handle_info({:gun_down, _, _, _, _}, state), do: {:noreply, state}
  def handle_info({:gun_error, _, _, _}, state), do: {:noreply, state}
  def handle_info({:gun_error, _, _}, state), do: {:noreply, state}

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
    adapter = state.config.shipper_adapter
    payload_bytes = batch |> :erlang.term_to_binary() |> byte_size()

    Logger.info(
      "[FlameOn] Shipping #{length(batch)} trace(s), payload size: #{format_bytes(payload_bytes)}"
    )

    case adapter.send_batch(batch, state.config) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[FlameOn] Failed to ship traces: #{inspect(reason)}")
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

  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format_bytes(bytes) when bytes >= 1_024, do: "#{Float.round(bytes / 1_024, 1)} KB"
  defp format_bytes(bytes), do: "#{bytes} B"

  defp build_config(opts) do
    defaults = %{
      shipper_adapter:
        Application.get_env(:flame_on_client, :shipper_adapter, FlameOn.Client.Shipper.Grpc),
      server_url: FlameOn.Client.env_or_config(:server_url, "flameon.ai"),
      use_ssl: FlameOn.Client.env_or_config_bool(:use_ssl, true),
      api_key: FlameOn.Client.env_or_config(:api_key, nil),
      flush_interval_ms: Application.get_env(:flame_on_client, :flush_interval_ms, 5_000),
      max_batch_size: Application.get_env(:flame_on_client, :max_batch_size, 50),
      max_buffer_size: Application.get_env(:flame_on_client, :max_buffer_size, 500)
    }

    Map.merge(defaults, Map.new(opts))
  end
end
