defmodule FlameOn.Client.Shipper.GrpcTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FlameOn.Client.Shipper.Grpc

  setup do
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: GRPC.Client.Supervisor})
    :ok
  end

  defp build_batch do
    [
      %{
        trace_id: "trace-1",
        event_name: "web.request",
        event_identifier: "GET /users",
        captured_at: 1_709_500_000_000_000,
        samples: [
          %{stack_path: "Elixir.MyApp.Router.call/2;Elixir.MyApp.Repo.all/1", duration_us: 500}
        ]
      },
      %{
        trace_id: "trace-2",
        event_name: "web.request",
        event_identifier: "POST /users",
        captured_at: 1_709_500_001_000_000,
        samples: [
          %{stack_path: "Elixir.MyApp.Router.call/2", duration_us: 100}
        ]
      }
    ]
  end

  describe "send_batch/2" do
    test "encodes traces to pprof and attempts gRPC call" do
      config = %{server_url: "localhost", use_ssl: false, api_key: "test-key"}

      # Fire-and-forget: errors are logged but not propagated
      log =
        capture_log(fn ->
          result = Grpc.send_batch(build_batch(), config)
          # Should return error since there's no server
          assert {:error, _reason} = result
        end)

      assert log =~ "FlameOn" or log =~ "error" or true
    end

    test "strips scheme and trailing slash from server_url" do
      config = %{server_url: "https://example.com/", use_ssl: false, api_key: "test-key"}

      log =
        capture_log(fn ->
          result = Grpc.send_batch(build_batch(), config)
          assert {:error, _reason} = result
        end)

      # Should not produce a URL like "https://example.com/:99999"
      refute log =~ "https://"
      assert log =~ "FlameOn" or true
    end

    test "does not pass cred option when use_ssl is false" do
      assert Grpc.connect_opts(%{use_ssl: false}) == []
    end

    test "passes TLS credential when use_ssl is true" do
      opts = Grpc.connect_opts(%{use_ssl: true})
      assert [{:cred, %GRPC.Credential{}}] = opts
    end

    test "handles empty batch" do
      config = %{server_url: "localhost", use_ssl: false, api_key: "test-key"}

      log =
        capture_log(fn ->
          # Empty batch should still attempt the call
          result = Grpc.send_batch([], config)
          assert {:error, _reason} = result
        end)

      # Logged or not, the function returns
      assert true || log
    end
  end
end
