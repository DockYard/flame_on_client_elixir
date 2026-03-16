defmodule FlameOn.Client.CollectorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias FlameOn.Client.Collector
  alias FlameOn.Client.TraceContext

  setup :verify_on_exit!

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
          events: [{[:test, :event, :start], threshold_ms: 0}],
          shipper_adapter: FlameOn.Client.Shipper.MockAdapter,
          server_url: "localhost",
          use_ssl: false,
          api_key: "test-key"
        ],
        opts
      )

    # Start shipper first (Collector sends to it)
    shipper = start_supervised!({FlameOn.Client.Shipper, shipper_opts}, id: :test_shipper)
    allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

    # Start TraceSessionSupervisor
    session_sup =
      start_supervised!(
        {FlameOn.Client.TraceSessionSupervisor, []},
        id: :test_session_sup
      )

    collector =
      start_supervised!(
        {Collector,
         collector_opts
         |> Keyword.put(:shipper_pid, shipper)
         |> Keyword.put(:trace_session_supervisor, session_sup)},
        id: :test_collector
      )

    allow(FlameOn.Client.Shipper.MockAdapter, self(), collector)

    %{collector: collector, shipper: shipper, session_sup: session_sup}
  end

  describe "telemetry attachment" do
    test "attaches handlers for configured events (bare list form)" do
      %{collector: _collector} =
        start_collector(events: [[:test, :collector, :alpha], [:test, :collector, :beta]])

      handlers = :telemetry.list_handlers([:test, :collector, :alpha])
      assert length(handlers) >= 1

      handler_ids = Enum.map(handlers, & &1.id)
      assert Enum.any?(handler_ids, &String.contains?(&1, "test_collector_alpha"))

      handlers_beta = :telemetry.list_handlers([:test, :collector, :beta])
      handler_ids_beta = Enum.map(handlers_beta, & &1.id)
      assert Enum.any?(handler_ids_beta, &String.contains?(&1, "test_collector_beta"))
    end

    test "attaches handlers for configured events (tuple form)" do
      %{collector: _collector} =
        start_collector(
          events: [
            {[:test, :collector, :gamma], threshold_ms: 500}
          ]
        )

      handlers = :telemetry.list_handlers([:test, :collector, :gamma])
      assert length(handlers) >= 1

      handler_ids = Enum.map(handlers, & &1.id)
      assert Enum.any?(handler_ids, &String.contains?(&1, "test_collector_gamma"))
    end
  end

  describe "telemetry event handling" do
    test "ignores telemetry for a dead collector" do
      pid = spawn(fn -> :ok end)

      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000

      assert :ok = Collector.handle_telemetry([:test, :event, :start], %{}, %{}, pid)
      assert :ok = Collector.handle_telemetry([:test, :event, :stop], %{}, %{}, pid)
    end

    test "sets and clears the current trace id around telemetry start and stop" do
      defmodule TraceContextHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle([:test, :event, :start], _measurements, _metadata) do
          {:capture, %{event_name: "test.event", event_identifier: "trace_context"}}
        end

        def handle(_, _, _), do: :skip
        def default_threshold_ms(_event), do: 0
      end

      %{collector: _collector} = start_collector(event_handler: TraceContextHandler)
      parent = self()

      pid =
        spawn(fn ->
          :telemetry.execute([:test, :event, :start], %{}, %{})
          send(parent, {:trace_id_after_start, TraceContext.current_trace_id()})
          :telemetry.execute([:test, :event, :stop], %{}, %{})
          send(parent, {:trace_id_after_stop, TraceContext.current_trace_id()})
        end)

      assert_receive {:trace_id_after_start, trace_id}, 1000
      assert is_binary(trace_id)
      assert trace_id != ""

      assert_receive {:trace_id_after_stop, nil}, 1000

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000
    end

    test "starts tracing when handler returns {:capture, info}" do
      defmodule TestHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle([:test, :event, :start], _measurements, _metadata) do
          {:capture, %{event_name: "test.event", event_identifier: "test"}}
        end

        def handle(_, _, _), do: :skip
        def default_threshold_ms(_event), do: 100
      end

      %{collector: collector} = start_collector(event_handler: TestHandler)

      # Execute telemetry in a process we control
      pid =
        spawn(fn ->
          :telemetry.execute([:test, :event, :start], %{}, %{})
          # Keep alive long enough for tracing to be set up
          Process.sleep(500)
        end)

      # Give the collector time to process the cast and start tracing
      Process.sleep(100)

      assert Collector.active_trace_count(collector) == 1
      Process.exit(pid, :kill)
    end

    test "does not trace when handler returns :skip" do
      defmodule SkipHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle(_, _, _), do: :skip
        def default_threshold_ms(_event), do: 100
      end

      %{collector: collector} = start_collector(event_handler: SkipHandler)

      pid =
        spawn(fn ->
          :telemetry.execute([:test, :event, :start], %{}, %{})
          Process.sleep(500)
        end)

      Process.sleep(100)

      assert Collector.active_trace_count(collector) == 0
      Process.exit(pid, :kill)
    end

    test "does not trace the same pid twice" do
      defmodule DoubleHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle([:test, :event, :start], _measurements, _metadata) do
          {:capture, %{event_name: "test.event", event_identifier: "test"}}
        end

        def handle(_, _, _), do: :skip
        def default_threshold_ms(_event), do: 100
      end

      %{collector: collector} = start_collector(event_handler: DoubleHandler)

      pid =
        spawn(fn ->
          :telemetry.execute([:test, :event, :start], %{}, %{})
          Process.sleep(50)
          :telemetry.execute([:test, :event, :start], %{}, %{})
          Process.sleep(500)
        end)

      Process.sleep(200)

      assert Collector.active_trace_count(collector) == 1
      Process.exit(pid, :kill)
    end

    test "respects sample_rate of 0.0" do
      defmodule AlwaysCaptureHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle([:test, :event, :start], _measurements, _metadata) do
          {:capture, %{event_name: "test.event", event_identifier: "test"}}
        end

        def handle(_, _, _), do: :skip
        def default_threshold_ms(_event), do: 100
      end

      %{collector: collector} =
        start_collector(event_handler: AlwaysCaptureHandler, sample_rate: 0.0)

      pid =
        spawn(fn ->
          :telemetry.execute([:test, :event, :start], %{}, %{})
          Process.sleep(500)
        end)

      Process.sleep(100)

      assert Collector.active_trace_count(collector) == 0
      Process.exit(pid, :kill)
    end
  end

  describe "logging" do
    test "logs when a trace capture starts" do
      defmodule LogHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle([:test, :event, :start], _measurements, _metadata) do
          {:capture, %{event_name: "test.event", event_identifier: "GET /users"}}
        end

        def handle(_, _, _), do: :skip
        def default_threshold_ms(_event), do: 100
      end

      log =
        capture_log(fn ->
          %{collector: _collector} = start_collector(event_handler: LogHandler)

          pid =
            spawn(fn ->
              :telemetry.execute([:test, :event, :start], %{}, %{})
              Process.sleep(500)
            end)

          Process.sleep(100)
          Process.exit(pid, :kill)
        end)

      assert log =~ "test.event"
      assert log =~ "GET /users"
    end
  end

  describe "trace lifecycle" do
    test "ships trace data when traced process exits" do
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:shipped, batch})
        :ok
      end)

      defmodule ShipHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle([:test, :event, :start], _measurements, _metadata) do
          {:capture, %{event_name: "test.event", event_identifier: "test_op"}}
        end

        def handle(_, _, _), do: :skip
        def default_threshold_ms(_event), do: 100
      end

      %{collector: _collector, shipper: shipper} =
        start_collector(
          event_handler: ShipHandler,
          flush_interval_ms: 50
        )

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      spawn(fn ->
        :telemetry.execute([:test, :event, :start], %{}, %{})
        # Keep alive long enough for tracing to start, then do some traced work
        Process.sleep(200)
        apply(String, :length, ["hello world"])
      end)

      assert_receive {:shipped, [trace_data]}, 5000

      assert trace_data.event_name == "test.event"
      assert trace_data.event_identifier == "test_op"
      assert is_binary(trace_data.trace_id)
      assert is_list(trace_data.samples)
    end

    test "ships trace data on stop event without process exit" do
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:shipped, batch})
        :ok
      end)

      defmodule StopEventHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle([:test, :event, :start], _measurements, _metadata) do
          {:capture, %{event_name: "test.event", event_identifier: "test_op"}}
        end

        def handle(_, _, _), do: :skip
        def default_threshold_ms(_event), do: 100
      end

      %{collector: collector, shipper: shipper} =
        start_collector(
          event_handler: StopEventHandler,
          flush_interval_ms: 50
        )

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      pid =
        spawn(fn ->
          :telemetry.execute([:test, :event, :start], %{}, %{})
          Process.sleep(200)
          apply(String, :length, ["hello world"])
          :telemetry.execute([:test, :event, :stop], %{duration: 200}, %{})
          # Process stays alive — simulates HTTP keep-alive
          Process.sleep(5_000)
        end)

      assert_receive {:shipped, [trace_data]}, 5000

      assert trace_data.event_name == "test.event"
      assert trace_data.event_identifier == "test_op"
      assert is_list(trace_data.samples)

      # Trace should be cleaned up even though process is still alive
      assert Collector.active_trace_count(collector) == 0
      assert Process.alive?(pid)

      Process.exit(pid, :kill)
    end

    test "cleans up active traces when process exits" do
      defmodule CleanupHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle([:test, :event, :start], _measurements, _metadata) do
          {:capture, %{event_name: "test.event", event_identifier: "test"}}
        end

        def handle(_, _, _), do: :skip
        def default_threshold_ms(_event), do: 100
      end

      %{collector: collector} = start_collector(event_handler: CleanupHandler)

      _pid =
        spawn(fn ->
          :telemetry.execute([:test, :event, :start], %{}, %{})
          Process.sleep(200)
        end)

      Process.sleep(100)
      assert Collector.active_trace_count(collector) == 1

      # Wait for process to exit naturally
      Process.sleep(200)

      # Give collector time to handle the DOWN message
      Process.sleep(100)

      assert Collector.active_trace_count(collector) == 0
    end

    test "shipped traces have a root block named after the event, not SLEEP" do
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:shipped, batch})
        :ok
      end)

      defmodule RootNameHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle([:test, :event, :start], _measurements, _metadata) do
          {:capture, %{event_name: "test.event", event_identifier: "my_op"}}
        end

        def handle(_, _, _), do: :skip
        def default_threshold_ms(_event), do: 100
      end

      %{collector: _collector, shipper: shipper} =
        start_collector(
          event_handler: RootNameHandler,
          flush_interval_ms: 50
        )

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      spawn(fn ->
        :telemetry.execute([:test, :event, :start], %{}, %{})
        Process.sleep(200)
        apply(String, :length, ["hello world"])
      end)

      assert_receive {:shipped, [trace_data]}, 5000

      # Every stack path should start with the event root, never SLEEP
      for sample <- trace_data.samples do
        refute String.starts_with?(sample.stack_path, "SLEEP"),
               "Stack path should not start with SLEEP: #{sample.stack_path}"

        assert String.starts_with?(sample.stack_path, "test.event my_op"),
               "Stack path should start with event root: #{sample.stack_path}"
      end
    end

    test "includes duration_us in shipped trace data" do
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:shipped, batch})
        :ok
      end)

      defmodule DurationHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle([:test, :event, :start], _measurements, _metadata) do
          {:capture, %{event_name: "test.event", event_identifier: "test_op"}}
        end

        def handle(_, _, _), do: :skip
        def default_threshold_ms(_event), do: 100
      end

      %{collector: _collector, shipper: shipper} =
        start_collector(
          event_handler: DurationHandler,
          flush_interval_ms: 50
        )

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      spawn(fn ->
        :telemetry.execute([:test, :event, :start], %{}, %{})
        Process.sleep(200)
        apply(String, :length, ["hello world"])
      end)

      assert_receive {:shipped, [trace_data]}, 5000

      assert is_integer(trace_data.duration_us)
      assert trace_data.duration_us > 0
    end
  end

  describe "trace completeness" do
    test "captures intermediate function calls, not just leaves" do
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:shipped, batch})
        :ok
      end)

      defmodule IntermediateHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle([:test, :event, :start], _measurements, _metadata) do
          {:capture, %{event_name: "test.event", event_identifier: "intermediate_test"}}
        end

        def handle(_, _, _), do: :skip
        def default_threshold_ms(_event), do: 100
      end

      %{collector: _collector, shipper: shipper} =
        start_collector(
          event_handler: IntermediateHandler,
          events: [{[:test, :event, :start], threshold_ms: 0}],
          flush_interval_ms: 50
        )

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      # Define a call chain: outer/0 -> middle/0 -> inner/0
      # All functions must be captured, not just the leaf
      defmodule TracedWork do
        def outer do
          middle()
        end

        def middle do
          inner()
        end

        def inner do
          Process.sleep(200)
        end
      end

      spawn(fn ->
        :telemetry.execute([:test, :event, :start], %{}, %{})
        # No sleep between telemetry and work — this is the key test.
        # Tracing must be active before outer/0 is called.
        TracedWork.outer()
      end)

      assert_receive {:shipped, [trace_data]}, 5000

      stack_paths = Enum.map(trace_data.samples, & &1.stack_path)
      all_stacks = Enum.join(stack_paths, "\n")

      # The intermediate function (outer) must appear in the stacks
      assert String.contains?(all_stacks, "TracedWork.outer/0"),
             "Expected outer/0 in stacks but got:\n#{all_stacks}"

      assert String.contains?(all_stacks, "TracedWork.middle/0"),
             "Expected middle/0 in stacks but got:\n#{all_stacks}"

      assert String.contains?(all_stacks, "TracedWork.inner/0"),
             "Expected inner/0 in stacks but got:\n#{all_stacks}"
    end
  end

  describe "threshold filtering" do
    test "ships traces that exceed the configured threshold" do
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:shipped, batch})
        :ok
      end)

      defmodule AboveThresholdHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle([:test, :event, :start], _measurements, _metadata) do
          {:capture, %{event_name: "test.event", event_identifier: "slow_op"}}
        end

        def handle(_, _, _), do: :skip
        def default_threshold_ms(_event), do: 100
      end

      # threshold_ms: 0 — any trace will be shipped
      %{collector: _collector, shipper: shipper} =
        start_collector(
          event_handler: AboveThresholdHandler,
          events: [{[:test, :event, :start], threshold_ms: 0}],
          flush_interval_ms: 50
        )

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      spawn(fn ->
        :telemetry.execute([:test, :event, :start], %{}, %{})
        Process.sleep(200)
        apply(String, :length, ["hello world"])
      end)

      assert_receive {:shipped, [trace_data]}, 5000
      assert trace_data.event_identifier == "slow_op"
    end

    test "drops traces below the configured threshold" do
      defmodule BelowThresholdHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle([:test, :event, :start], _measurements, _metadata) do
          {:capture, %{event_name: "test.event", event_identifier: "fast_op"}}
        end

        def handle(_, _, _), do: :skip
        def default_threshold_ms(_event), do: 100
      end

      # threshold_ms: 60_000 means 60 seconds — trace will be way below
      %{collector: _collector, shipper: shipper} =
        start_collector(
          event_handler: BelowThresholdHandler,
          events: [{[:test, :event, :start], threshold_ms: 60_000}],
          flush_interval_ms: 50
        )

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      spawn(fn ->
        :telemetry.execute([:test, :event, :start], %{}, %{})
        Process.sleep(100)
        apply(String, :length, ["hello"])
      end)

      # Wait for process to exit and collector to process
      Process.sleep(500)

      refute_receive {:shipped, _}, 200
    end

    test "uses handler default threshold when no threshold_ms option given" do
      defmodule DefaultThresholdHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle([:test, :event, :start], _measurements, _metadata) do
          {:capture, %{event_name: "test.event", event_identifier: "default_op"}}
        end

        def handle(_, _, _), do: :skip

        # Very high default — traces will be dropped
        def default_threshold_ms([:test, :event, :start]), do: 60_000
        def default_threshold_ms(_event), do: 100
      end

      %{collector: _collector, shipper: shipper} =
        start_collector(
          event_handler: DefaultThresholdHandler,
          events: [[:test, :event, :start]],
          flush_interval_ms: 50
        )

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      spawn(fn ->
        :telemetry.execute([:test, :event, :start], %{}, %{})
        Process.sleep(100)
        apply(String, :length, ["hello"])
      end)

      Process.sleep(500)

      refute_receive {:shipped, _}, 200
    end

    test "threshold_ms option overrides handler default" do
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:shipped, batch})
        :ok
      end)

      defmodule OverrideThresholdHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle([:test, :event, :start], _measurements, _metadata) do
          {:capture, %{event_name: "test.event", event_identifier: "override_op"}}
        end

        def handle(_, _, _), do: :skip

        # Handler says 60s, but config will override to 0ms
        def default_threshold_ms([:test, :event, :start]), do: 60_000
        def default_threshold_ms(_event), do: 100
      end

      %{collector: _collector, shipper: shipper} =
        start_collector(
          event_handler: OverrideThresholdHandler,
          events: [{[:test, :event, :start], threshold_ms: 0}],
          flush_interval_ms: 50
        )

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      spawn(fn ->
        :telemetry.execute([:test, :event, :start], %{}, %{})
        Process.sleep(200)
        apply(String, :length, ["hello world"])
      end)

      assert_receive {:shipped, [trace_data]}, 5000
      assert trace_data.event_identifier == "override_op"
    end
  end

  describe "deadlock prevention" do
    test "collector responds to calls while traces are active" do
      defmodule DeadlockHandler do
        @behaviour FlameOn.Client.EventHandler

        def handle([:test, :event, :start], _measurements, _metadata) do
          {:capture, %{event_name: "test.event", event_identifier: "deadlock_test"}}
        end

        def handle(_, _, _), do: :skip
        def default_threshold_ms(_event), do: 100
      end

      %{collector: collector} =
        start_collector(
          event_handler: DeadlockHandler,
          events: [{[:test, :event, :start], threshold_ms: 0}]
        )

      # Spawn multiple processes that generate heavy trace traffic
      pids =
        for _ <- 1..5 do
          spawn(fn ->
            :telemetry.execute([:test, :event, :start], %{}, %{})
            # Do CPU work to generate lots of trace messages
            Enum.reduce(1..1000, 0, fn i, acc -> acc + i end)
            Process.sleep(500)
          end)
        end

      # Give time for traces to start and generate traffic
      Process.sleep(100)

      # The key assertion: collector must respond within 200ms timeout
      # With the old architecture this would deadlock under trace message flood
      assert Collector.active_trace_count(collector) >= 1

      for pid <- pids, do: Process.exit(pid, :kill)
    end
  end
end
