defmodule FlameOn.Client.CircuitBreakerIntegrationTest do
  use ExUnit.Case, async: false

  import Mox

  alias FlameOn.Client.CircuitBreaker
  alias FlameOn.Client.Collector

  setup :verify_on_exit!

  setup do
    CircuitBreaker.enable!()
    :ets.delete_all_objects(:flame_on_trace_dedupe)

    on_exit(fn ->
      CircuitBreaker.enable!()
    end)

    :ok
  end

  defp start_collector(opts) do
    shipper_opts =
      Keyword.merge(
        [
          shipper_adapter: FlameOn.Client.Shipper.MockAdapter,
          flush_interval_ms: 100_000,
          max_batch_size: 50,
          max_buffer_size: 500,
          server_url: "localhost",
          use_ssl: false,
          api_key: "test-key"
        ],
        Keyword.take(opts, [
          :flush_interval_ms,
          :max_batch_size,
          :max_buffer_size,
          :shipper_adapter
        ])
      )

    collector_opts =
      Keyword.merge(
        [
          event_handler: FlameOn.Client.EventHandler.Default,
          sample_rate: 1.0,
          events: [{[:test, :cb_event, :start], threshold_ms: 0}],
          shipper_adapter: FlameOn.Client.Shipper.MockAdapter,
          server_url: "localhost",
          use_ssl: false,
          api_key: "test-key"
        ],
        opts
      )

    shipper = start_supervised!({FlameOn.Client.Shipper, shipper_opts}, id: :cb_test_shipper)
    allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

    session_sup =
      start_supervised!(
        {FlameOn.Client.TraceSessionSupervisor, []},
        id: :cb_test_session_sup
      )

    seq_trace_router =
      start_supervised!(FlameOn.Client.SeqTraceRouter, id: :cb_test_seq_trace_router)

    collector =
      start_supervised!(
        {Collector,
         collector_opts
         |> Keyword.put(:shipper_pid, shipper)
         |> Keyword.put(:trace_session_supervisor, session_sup)
         |> Keyword.put(:seq_trace_router, seq_trace_router)},
        id: :cb_test_collector
      )

    allow(FlameOn.Client.Shipper.MockAdapter, self(), collector)

    %{collector: collector, shipper: shipper, session_sup: session_sup}
  end

  describe "collector skips when circuit breaker is tripped" do
    test "does not start traces when circuit breaker is disabled" do
      defmodule CBTestHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle([:test, :cb_event, :start], _measurements, _metadata) do
          {:capture, %{event_name: "test.cb_event", event_identifier: "cb_test"}}
        end

        def handle(_, _, _), do: :skip
        def default_threshold_ms(_event), do: 100
      end

      %{collector: collector} = start_collector(event_handler: CBTestHandler)

      # Trip the circuit breaker
      CircuitBreaker.disable!()

      pid =
        spawn(fn ->
          :telemetry.execute([:test, :cb_event, :start], %{}, %{})
          Process.sleep(500)
        end)

      Process.sleep(100)

      assert Collector.active_trace_count(collector) == 0
      Process.exit(pid, :kill)
    end

    test "resumes tracing when circuit breaker is re-enabled" do
      defmodule CBResumeHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle([:test, :cb_event, :start], _measurements, _metadata) do
          {:capture, %{event_name: "test.cb_event", event_identifier: "cb_resume"}}
        end

        def handle(_, _, _), do: :skip
        def default_threshold_ms(_event), do: 100
      end

      # Disable dedupe for this test so it doesn't interfere
      Application.put_env(:flame_on_client, :dedupe_enabled, false)

      %{collector: collector} = start_collector(event_handler: CBResumeHandler)

      # Trip and then re-enable
      CircuitBreaker.disable!()
      CircuitBreaker.enable!()

      pid =
        spawn(fn ->
          :telemetry.execute([:test, :cb_event, :start], %{}, %{})
          Process.sleep(500)
        end)

      Process.sleep(100)

      assert Collector.active_trace_count(collector) == 1
      Process.exit(pid, :kill)
    after
      Application.delete_env(:flame_on_client, :dedupe_enabled)
    end
  end
end
