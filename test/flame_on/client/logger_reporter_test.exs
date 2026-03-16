defmodule FlameOn.Client.LoggerReporterTest do
  use ExUnit.Case, async: false

  import Mox

  alias FlameOn.Client.ErrorShipper
  alias FlameOn.Client.LoggerReporter

  setup :verify_on_exit!

  test "captures error logger events" do
    test_pid = self()

    FlameOn.Client.ErrorShipper.MockAdapter
    |> expect(:send_batch, fn [%FlameOn.ErrorEvent{} = event], _config ->
      send(test_pid, {:captured, event})
      :ok
    end)

    pid =
      start_supervised!(
        {ErrorShipper,
         [
           name: FlameOn.Client.ErrorShipper,
           flush_interval_ms: 50,
           max_batch_size: 1,
           shipper_adapter: FlameOn.Client.ErrorShipper.MockAdapter,
           api_key: "test-key",
           server_url: "localhost",
           use_ssl: false
         ]},
        id: :logger_error_shipper
      )

    allow(FlameOn.Client.ErrorShipper.MockAdapter, self(), pid)

    assert :ok =
             LoggerReporter.capture_log_event(%{
               level: :error,
               msg: {:string, "database unavailable"},
               meta: %{mfa: {MyApp.Worker, :perform, 1}, line: 42}
             })

    assert_receive {:captured, event}, 1000
    assert event.message =~ "database unavailable"
    assert event.route == "logger.error"
    refute event.handled
    assert event.severity == "error"
    assert Enum.any?(event.tags, &(&1.key == "logger_source" and &1.value == "fallback"))
  end

  test "ignores FlameOn internal logger events" do
    pid =
      start_supervised!(
        {ErrorShipper,
         [
           name: FlameOn.Client.ErrorShipper,
           flush_interval_ms: 50,
           max_batch_size: 1,
           shipper_adapter: FlameOn.Client.ErrorShipper.MockAdapter,
           api_key: "test-key",
           server_url: "localhost",
           use_ssl: false
         ]},
        id: :logger_ignore_shipper
      )

    allow(FlameOn.Client.ErrorShipper.MockAdapter, self(), pid)

    assert :ok =
             LoggerReporter.capture_log_event(%{
               level: :error,
               msg: {:string, "[FlameOn] nope"},
               meta: %{}
             })

    Process.sleep(100)
    assert ErrorShipper.buffer_size(pid) == 0
  end
end
