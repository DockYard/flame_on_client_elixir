defmodule FlameOn.Client.ShipperTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mox

  alias FlameOn.Client.Shipper

  setup :verify_on_exit!

  defp start_shipper(opts \\ []) do
    opts =
      Keyword.merge(
        [
          flush_interval_ms: 100_000,
          max_batch_size: 50,
          max_buffer_size: 500,
          server_url: "localhost",
          use_ssl: false,
          api_key: "test-key",
          shipper_adapter: FlameOn.Client.Shipper.MockAdapter
        ],
        opts
      )

    pid = start_supervised!({Shipper, opts})
    allow(FlameOn.Client.Shipper.MockAdapter, self(), pid)
    pid
  end

  describe "push/2" do
    test "buffers a trace" do
      pid = start_shipper()

      Shipper.push(pid, %{trace_id: "abc", samples: []})

      assert Shipper.buffer_size(pid) == 1
    end

    test "buffers multiple traces" do
      pid = start_shipper()

      Shipper.push(pid, %{trace_id: "1", samples: []})
      Shipper.push(pid, %{trace_id: "2", samples: []})
      Shipper.push(pid, %{trace_id: "3", samples: []})

      assert Shipper.buffer_size(pid) == 3
    end
  end

  describe "flush on max_batch_size" do
    test "flushes when buffer reaches max_batch_size" do
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:batch_sent, length(batch)})
        :ok
      end)

      pid = start_shipper(max_batch_size: 3)

      Shipper.push(pid, %{trace_id: "1", samples: []})
      Shipper.push(pid, %{trace_id: "2", samples: []})
      Shipper.push(pid, %{trace_id: "3", samples: []})

      assert_receive {:batch_sent, 3}, 1000
      assert Shipper.buffer_size(pid) == 0
    end
  end

  describe "flush on interval" do
    test "flushes on timer interval" do
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:batch_sent, length(batch)})
        :ok
      end)

      pid = start_shipper(flush_interval_ms: 50)

      Shipper.push(pid, %{trace_id: "1", samples: []})

      assert_receive {:batch_sent, 1}, 1000
    end

    test "does not flush when buffer is empty" do
      _pid = start_shipper(flush_interval_ms: 50)

      # Wait past the flush interval — no expectations set, so if send_batch
      # is called Mox will fail in verify_on_exit!
      Process.sleep(100)
    end
  end

  describe "max_buffer_size protection" do
    test "drops oldest items when buffer exceeds max_buffer_size" do
      pid = start_shipper(max_buffer_size: 3)

      Shipper.push(pid, %{trace_id: "1", samples: []})
      Shipper.push(pid, %{trace_id: "2", samples: []})
      Shipper.push(pid, %{trace_id: "3", samples: []})
      Shipper.push(pid, %{trace_id: "4", samples: []})

      assert Shipper.buffer_size(pid) == 3
    end
  end

  describe "logging" do
    test "logs payload size when flushing" do
      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn _batch, _config -> :ok end)

      pid = start_shipper(flush_interval_ms: 50)

      log =
        capture_log(fn ->
          Shipper.push(pid, %{
            trace_id: "1",
            samples: [%{stack_path: "Foo.bar/1", duration_us: 100}]
          })

          Process.sleep(100)
        end)

      assert log =~ "[FlameOn] Shipping"
      assert log =~ "trace(s)"
      assert log =~ ~r/\d+(\.\d+)?\s*(B|KB|MB)/
    end
  end

  describe "gun messages" do
    test "ignores async gun_data messages without crashing" do
      pid = start_shipper()

      send(pid, {:gun_data, self(), make_ref(), :fin, "Not Found"})

      # Process should still be alive
      assert Process.alive?(pid)
      assert Shipper.buffer_size(pid) == 0
    end
  end

  describe "error handling" do
    test "drops traces when send_batch fails" do
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn _batch, _config ->
        send(test_pid, :batch_attempted)
        {:error, :connection_refused}
      end)

      pid = start_shipper(flush_interval_ms: 50)

      capture_log(fn ->
        Shipper.push(pid, %{trace_id: "1", samples: []})
        assert_receive :batch_attempted, 1000
      end)

      # Buffer should be cleared after failed send — no retries
      assert Shipper.buffer_size(pid) == 0
    end

    test "logs error when send_batch fails" do
      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn _batch, _config ->
        {:error, :connection_refused}
      end)

      pid = start_shipper(flush_interval_ms: 50)

      log =
        capture_log(fn ->
          Shipper.push(pid, %{trace_id: "1", samples: []})
          Process.sleep(100)
        end)

      assert log =~ "[FlameOn] Failed to ship traces"
      assert log =~ "connection_refused"
    end

    test "logs error on HTTP error status" do
      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn _batch, _config ->
        {:error, {:http_error, 413, "Request too large"}}
      end)

      pid = start_shipper(flush_interval_ms: 50)

      log =
        capture_log(fn ->
          Shipper.push(pid, %{trace_id: "1", samples: []})
          Process.sleep(100)
        end)

      assert log =~ "[FlameOn] Failed to ship traces"
      assert log =~ "413"
    end
  end
end
