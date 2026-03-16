defmodule FlameOn.Client.LiveViewReporterTest do
  use ExUnit.Case, async: false

  import Mox

  alias FlameOn.Client.ErrorShipper
  alias FlameOn.Client.LiveViewReporter

  setup :verify_on_exit!

  test "captures a LiveView exception with event metadata" do
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
        id: :live_view_error_shipper
      )

    allow(FlameOn.Client.ErrorShipper.MockAdapter, self(), pid)

    socket = %{
      view: MyAppWeb.UserLive,
      assigns: %{current_user: %{id: 123, email: "dev@example.test"}}
    }

    try do
      raise "save failed"
    rescue
      exception ->
        assert :ok = LiveViewReporter.capture_exception(socket, "save", exception, __STACKTRACE__)
    end

    assert_receive {:captured, event}, 1000
    assert event.message == "save failed"
    assert event.route == "live_view.event"
    refute event.handled
    assert Enum.any?(event.tags, &(&1.key == "view" and &1.value == "MyAppWeb.UserLive"))
    assert Enum.any?(event.tags, &(&1.key == "event" and &1.value == "save"))
    assert event.user.id == "123"
  end
end
