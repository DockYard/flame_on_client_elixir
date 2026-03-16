defmodule FlameOn.Client.Shipper.Grpc do
  @behaviour FlameOn.Client.Shipper.Behaviour

  require Logger

  alias FlameOn.Client.PprofEncoder

  @grpc_port 50051

  @impl true
  def send_batch(batch, config) do
    traces = Enum.map(batch, &PprofEncoder.encode/1)
    request = %FlameOn.IngestRequest{traces: traces}

    url =
      config.server_url
      |> String.replace(~r{^https?://}, "")
      |> String.trim_trailing("/")

    case GRPC.Stub.connect("#{url}:#{@grpc_port}", connect_opts(config)) do
      {:ok, channel} ->
        metadata = %{"authorization" => "Bearer #{config.api_key}"}

        result =
          case FlameOn.FlameOnIngest.Stub.ingest(channel, request, metadata: metadata) do
            {:ok, %FlameOn.IngestResponse{success: true}} ->
              :ok

            {:ok, %FlameOn.IngestResponse{success: false, message: message}} ->
              Logger.warning("[FlameOn] gRPC ingest rejected: #{message}")
              {:error, {:rejected, message}}

            {:error, reason} ->
              Logger.warning("[FlameOn] gRPC ingest failed: #{inspect(reason)}")
              {:error, reason}
          end

        safe_disconnect(channel)
        result

      {:error, reason} ->
        Logger.warning("[FlameOn] gRPC connection failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc false
  def connect_opts(%{use_ssl: true}) do
    ssl_opts = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get()
    ]

    [cred: GRPC.Credential.new(ssl: ssl_opts)]
  end

  def connect_opts(%{use_ssl: false}), do: []

  # Workaround for grpc 0.11.5 disconnect bug:
  # https://github.com/elixir-grpc/grpc/issues/492
  # GRPC.Stub.disconnect/1 crashes with FunctionClauseError because the
  # disconnect handler pattern-matches {:ok, ch} but direct connections
  # store bare channel structs. Fixed in PR #493 but not yet released.
  # TODO: revert to GRPC.Stub.disconnect(channel) when grpc > 0.11.5
  defp safe_disconnect(%GRPC.Channel{ref: ref}) do
    case :global.whereis_name({GRPC.Client.Connection, ref}) do
      :undefined -> :ok
      pid -> GenServer.stop(pid, :normal, 5_000)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
