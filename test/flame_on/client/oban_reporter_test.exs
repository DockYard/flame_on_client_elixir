defmodule FlameOn.Client.ObanReporterTest do
  use ExUnit.Case, async: false

  import Mox

  alias FlameOn.Client.ErrorShipper
  alias FlameOn.Client.ObanReporter

  setup :verify_on_exit!

  test "captures an Oban job exception with job metadata" do
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
        id: :oban_error_shipper
      )

    allow(FlameOn.Client.ErrorShipper.MockAdapter, self(), pid)

    job = %{
      id: 123,
      worker: "MyApp.Workers.SendEmail",
      queue: "mailers",
      args: %{"email_id" => 42},
      attempt: 2,
      max_attempts: 10
    }

    try do
      raise "job failed"
    rescue
      exception ->
        assert :ok = ObanReporter.capture_exception(job, exception, __STACKTRACE__)
    end

    assert_receive {:captured, event}, 1000
    assert event.message == "job failed"
    refute event.handled
    assert event.route == "oban.job"
    assert Enum.any?(event.tags, &(&1.key == "queue" and &1.value == "mailers"))
    assert Enum.any?(event.tags, &(&1.key == "worker" and &1.value == "MyApp.Workers.SendEmail"))
    assert Enum.any?(event.contexts, &(&1.key == "job_id" and &1.value == "123"))
    assert Enum.any?(event.contexts, &(&1.key == "attempt" and &1.value == "2"))
    assert Enum.any?(event.contexts, &(&1.key == "args" and &1.value =~ "email_id"))
    assert Enum.any?(event.breadcrumbs, &(&1.category == "oban" and &1.message == "job failed"))
  end
end
