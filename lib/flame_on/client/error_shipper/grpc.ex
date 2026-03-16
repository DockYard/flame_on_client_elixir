defmodule FlameOn.Client.ErrorShipper.Grpc do
  @behaviour FlameOn.Client.ErrorShipper.Behaviour

  require Logger

  @grpc_port 50051

  @impl true
  def send_batch(batch, config) do
    request = %FlameOn.IngestErrorsRequest{events: batch}

    url =
      config.server_url
      |> String.replace(~r{^https?://}, "")
      |> String.trim_trailing("/")

    case GRPC.Stub.connect(
           "#{url}:#{@grpc_port}",
           FlameOn.Client.Shipper.Grpc.connect_opts(config)
         ) do
      {:ok, channel} ->
        metadata = %{"authorization" => "Bearer #{config.api_key}"}

        result =
          case FlameOn.FlameOnErrorIngest.Stub.ingest_errors(channel, request, metadata: metadata) do
            {:ok, %FlameOn.IngestErrorsResponse{success: true}} ->
              :ok

            {:ok, %FlameOn.IngestErrorsResponse{success: false, warnings: warnings}} ->
              Logger.warning("[FlameOn] gRPC error ingest rejected: #{inspect(warnings)}")
              {:error, {:rejected, warnings}}

            {:error, reason} ->
              Logger.warning("[FlameOn] gRPC error ingest failed: #{inspect(reason)}")
              {:error, reason}
          end

        safe_disconnect(channel)
        result

      {:error, reason} ->
        Logger.warning("[FlameOn] gRPC error connection failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

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
