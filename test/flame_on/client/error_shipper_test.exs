defmodule FlameOn.Client.ErrorShipperTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mox

  alias FlameOn.Client.ErrorShipper

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
          shipper_adapter: FlameOn.Client.ErrorShipper.MockAdapter
        ],
        opts
      )

    pid = start_supervised!({ErrorShipper, opts})
    allow(FlameOn.Client.ErrorShipper.MockAdapter, self(), pid)
    pid
  end

  defp sample_event(message \\ "boom") do
    %FlameOn.ErrorEvent{
      event_id: "evt_123",
      platform: "elixir",
      environment: "test",
      service: "my_app",
      severity: "error",
      message: message,
      handled: true
    }
  end

  test "buffers an error event" do
    pid = start_shipper()

    ErrorShipper.push(pid, sample_event())

    assert ErrorShipper.buffer_size(pid) == 1
  end

  test "flushes when buffer reaches max_batch_size" do
    test_pid = self()

    FlameOn.Client.ErrorShipper.MockAdapter
    |> expect(:send_batch, fn batch, _config ->
      send(test_pid, {:batch_sent, length(batch)})
      :ok
    end)

    pid = start_shipper(max_batch_size: 2)

    ErrorShipper.push(pid, sample_event("one"))
    ErrorShipper.push(pid, sample_event("two"))

    assert_receive {:batch_sent, 2}, 1000
    assert ErrorShipper.buffer_size(pid) == 0
  end

  test "logs failures and drops buffered events" do
    FlameOn.Client.ErrorShipper.MockAdapter
    |> expect(:send_batch, fn _batch, _config ->
      {:error, :connection_refused}
    end)

    pid = start_shipper(flush_interval_ms: 50)

    log =
      capture_log(fn ->
        ErrorShipper.push(pid, sample_event())
        Process.sleep(100)
      end)

    assert log =~ "[FlameOn] Failed to ship errors"
    assert ErrorShipper.buffer_size(pid) == 0
  end
end
