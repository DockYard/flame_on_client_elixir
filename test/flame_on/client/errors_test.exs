defmodule FlameOn.Client.ErrorsTest do
  use ExUnit.Case, async: false

  import Mox

  alias FlameOn.Client.ErrorShipper
  alias FlameOn.Client.ErrorContext
  alias FlameOn.Client.ErrorDedupe
  alias FlameOn.Client.Errors
  alias FlameOn.Client.TraceContext

  setup :verify_on_exit!

  setup do
    ErrorDedupe.clear()
    :ok
  end

  test "capture_exception/2 builds and enqueues an error event" do
    test_pid = self()
    original_service = Application.get_env(:flame_on_client, :service)
    original_environment = Application.get_env(:flame_on_client, :environment)
    original_release = Application.get_env(:flame_on_client, :release)

    on_exit(fn ->
      Application.put_env(:flame_on_client, :service, original_service)
      Application.put_env(:flame_on_client, :environment, original_environment)
      Application.put_env(:flame_on_client, :release, original_release)
    end)

    Application.put_env(:flame_on_client, :service, "my_app")
    Application.put_env(:flame_on_client, :environment, "test")
    Application.put_env(:flame_on_client, :release, "0.1.0")

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
        id: :error_shipper
      )

    allow(FlameOn.Client.ErrorShipper.MockAdapter, self(), pid)

    try do
      raise "boom"
    rescue
      exception ->
        assert :ok =
                 Errors.capture_exception(exception,
                   stacktrace: __STACKTRACE__,
                   request: %{method: "GET", url: "https://example.test/fail"}
                 )
    end

    assert_receive {:captured, event}, 1000
    assert event.message == "boom"
    assert event.service == "my_app"
    assert event.environment == "test"
    assert event.release == "0.1.0"
    assert event.request.method == "GET"
  end

  test "capture_exception/2 is a no-op when error shipper is not running" do
    assert :ok = Errors.capture_exception(%RuntimeError{message: "boom"})
  end

  test "capture_message/2 uses the current trace id when present" do
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
        id: :trace_context_error_shipper
      )

    allow(FlameOn.Client.ErrorShipper.MockAdapter, self(), pid)
    TraceContext.put_trace_id("123e4567-e89b-12d3-a456-426614174000")

    on_exit(fn ->
      TraceContext.clear()
    end)

    assert :ok = Errors.capture_message("boom")

    assert_receive {:captured, event}, 1000
    assert event.trace_id == "123e4567-e89b-12d3-a456-426614174000"
  end

  test "before_send can mutate the outgoing event" do
    test_pid = self()
    original_before_send = Application.get_env(:flame_on_client, :before_send)

    on_exit(fn ->
      Application.put_env(:flame_on_client, :before_send, original_before_send)
    end)

    Application.put_env(:flame_on_client, :before_send, fn event ->
      %{event | severity: "warning", message: "rewritten"}
    end)

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
        id: :before_send_error_shipper
      )

    allow(FlameOn.Client.ErrorShipper.MockAdapter, self(), pid)

    assert :ok = Errors.capture_message("boom")

    assert_receive {:captured, event}, 1000
    assert event.severity == "warning"
    assert event.message == "rewritten"
  end

  test "before_send can drop the outgoing event" do
    original_before_send = Application.get_env(:flame_on_client, :before_send)

    on_exit(fn ->
      Application.put_env(:flame_on_client, :before_send, original_before_send)
    end)

    Application.put_env(:flame_on_client, :before_send, fn _event -> nil end)

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
        id: :before_send_drop_shipper
      )

    allow(FlameOn.Client.ErrorShipper.MockAdapter, self(), pid)

    assert :ok = Errors.capture_message("drop me")
    Process.sleep(100)
    assert ErrorShipper.buffer_size(pid) == 0
  end

  test "process context is included in captured events" do
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
        id: :context_error_shipper
      )

    allow(FlameOn.Client.ErrorShipper.MockAdapter, self(), pid)

    on_exit(fn ->
      ErrorContext.clear()
    end)

    :ok = Errors.set_user(%{id: 123, email: "dev@example.test"})
    :ok = Errors.set_tags(%{region: "test", area: "billing"})
    :ok = Errors.set_context(:tenant, %{id: "tenant_123"})
    :ok = Errors.add_breadcrumb(%{category: "request", message: "started", level: "info"})

    assert :ok = Errors.capture_message("boom")

    assert_receive {:captured, event}, 1000
    assert event.user.id == "123"
    assert event.user.email == "dev@example.test"
    assert Enum.any?(event.tags, &(&1.key == "region" and &1.value == "test"))
    assert Enum.any?(event.tags, &(&1.key == "area" and &1.value == "billing"))

    assert Enum.any?(
             event.contexts,
             &(&1.key == "tenant" and &1.value =~ "%{id: \"tenant_123\"}")
           )

    assert Enum.any?(event.breadcrumbs, &(&1.category == "request" and &1.message == "started"))
  end

  test "clear_context removes stored process context" do
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
        id: :clear_context_error_shipper
      )

    allow(FlameOn.Client.ErrorShipper.MockAdapter, self(), pid)

    :ok = Errors.set_user(%{id: 123, email: "dev@example.test"})
    :ok = Errors.set_tags(%{region: "test"})
    :ok = Errors.add_breadcrumb(%{category: "request", message: "started"})
    :ok = Errors.clear_context()

    assert :ok = Errors.capture_message("boom")

    assert_receive {:captured, event}, 1000
    assert is_nil(event.user)
    assert event.tags == []
    assert event.breadcrumbs == []
  end

  test "duplicate suppression drops repeated events within the dedupe window" do
    test_pid = self()
    original_window = Application.get_env(:flame_on_client, :error_dedupe_window_ms)

    on_exit(fn ->
      Application.put_env(:flame_on_client, :error_dedupe_window_ms, original_window)
      ErrorDedupe.clear()
    end)

    Application.put_env(:flame_on_client, :error_dedupe_window_ms, 1_000)

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
        id: :dedupe_error_shipper
      )

    allow(FlameOn.Client.ErrorShipper.MockAdapter, self(), pid)

    assert :ok = Errors.capture_message("same error")
    assert :ok = Errors.capture_message("same error")

    assert_receive {:captured, event}, 1000
    assert event.message == "same error"
    refute_receive {:captured, _}, 200
  end

  test "duplicate suppression expires after the dedupe window" do
    test_pid = self()
    original_window = Application.get_env(:flame_on_client, :error_dedupe_window_ms)

    on_exit(fn ->
      Application.put_env(:flame_on_client, :error_dedupe_window_ms, original_window)
      ErrorDedupe.clear()
    end)

    Application.put_env(:flame_on_client, :error_dedupe_window_ms, 50)

    FlameOn.Client.ErrorShipper.MockAdapter
    |> expect(:send_batch, 2, fn [%FlameOn.ErrorEvent{} = event], _config ->
      send(test_pid, {:captured, event.message})
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
        id: :dedupe_expiry_error_shipper
      )

    allow(FlameOn.Client.ErrorShipper.MockAdapter, self(), pid)

    assert :ok = Errors.capture_message("same error")
    assert_receive {:captured, "same error"}, 1000

    Process.sleep(60)

    assert :ok = Errors.capture_message("same error")
    assert_receive {:captured, "same error"}, 1000
  end
end
