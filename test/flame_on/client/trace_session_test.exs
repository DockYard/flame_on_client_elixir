defmodule FlameOn.Client.TraceSessionTest do
  use ExUnit.Case, async: false

  import Mox

  alias FlameOn.Client.Capture.Trace
  alias FlameOn.Client.TraceSession

  setup :verify_on_exit!

  defp start_shipper(opts \\ []) do
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
        opts
      )

    shipper = start_supervised!({FlameOn.Client.Shipper, shipper_opts}, id: :test_shipper)
    allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)
    shipper
  end

  describe "init/1" do
    test "starts tracing on the target process" do
      shipper = start_shipper()

      target =
        spawn(fn ->
          Process.sleep(5_000)
        end)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "test_op",
        trace_id: "abc-123",
        threshold_us: 0
      }

      {:ok, session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.01
        )

      assert Process.alive?(session)

      # Cleanup
      Trace.stop_trace(target)
      Process.exit(target, :kill)
      Process.exit(session, :kill)
    end

    test "stops if traced process is already dead" do
      shipper = start_shipper()

      target = spawn(fn -> :ok end)
      # Wait for process to die
      Process.sleep(50)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "test_op",
        trace_id: "abc-123",
        threshold_us: 0
      }

      # start_link propagates {:stop, reason} as an EXIT — trap it
      Process.flag(:trap_exit, true)

      result =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.01
        )

      # Should fail to start since the process is dead
      assert {:error, :process_not_alive} = result

      Process.flag(:trap_exit, false)
    end
  end

  describe "trace message handling" do
    test "processes trace messages and builds stack" do
      shipper = start_shipper(flush_interval_ms: 50)
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:shipped, batch})
        :ok
      end)

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      target =
        spawn(fn ->
          Process.sleep(200)
          apply(String, :length, ["hello world"])
        end)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "stack_test",
        trace_id: "abc-123",
        threshold_us: 0
      }

      {:ok, _session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.01
        )

      # Wait for process to exit naturally and session to finalize
      assert_receive {:shipped, [trace_data]}, 5000

      assert trace_data.event_name == "test.event"
      assert trace_data.event_identifier == "stack_test"
      assert is_list(trace_data.samples)
    end
  end

  describe "finalize and ship on :stop cast" do
    test "finalizes and ships when receiving :stop cast" do
      shipper = start_shipper(flush_interval_ms: 50)
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:shipped, batch})
        :ok
      end)

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      target =
        spawn(fn ->
          Process.sleep(200)
          apply(String, :length, ["hello world"])
          # Keep alive — simulates HTTP keep-alive
          Process.sleep(5_000)
        end)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "stop_test",
        trace_id: "abc-123",
        threshold_us: 0
      }

      {:ok, session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.01
        )

      # Give time for trace messages to accumulate
      Process.sleep(300)

      # Send stop
      GenServer.cast(session, :stop)

      assert_receive {:shipped, [trace_data]}, 5000
      assert trace_data.event_name == "test.event"
      assert trace_data.event_identifier == "stop_test"

      # Session should terminate after shipping
      Process.sleep(100)
      refute Process.alive?(session)

      # Cleanup
      Process.exit(target, :kill)
    end
  end

  describe "finalize and ship on traced process DOWN" do
    test "finalizes and ships when traced process exits" do
      shipper = start_shipper(flush_interval_ms: 50)
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:shipped, batch})
        :ok
      end)

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      target =
        spawn(fn ->
          Process.sleep(200)
          apply(String, :length, ["hello world"])
        end)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "down_test",
        trace_id: "abc-123",
        threshold_us: 0
      }

      {:ok, session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.01
        )

      # Wait for process to exit naturally
      assert_receive {:shipped, [trace_data]}, 5000
      assert trace_data.event_name == "test.event"
      assert trace_data.event_identifier == "down_test"

      # Session should terminate after shipping
      Process.sleep(100)
      refute Process.alive?(session)
    end
  end

  describe "threshold filtering" do
    test "drops traces below threshold" do
      shipper = start_shipper(flush_interval_ms: 50)

      target =
        spawn(fn ->
          Process.sleep(100)
          apply(String, :length, ["hello"])
        end)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "fast_op",
        trace_id: "abc-123",
        # 60 second threshold — trace will be way below
        threshold_us: 60_000_000
      }

      {:ok, _session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.01
        )

      # Wait for process to exit and session to process
      Process.sleep(500)

      refute_receive {:shipped, _}, 200
    end
  end

  describe "cross-process call tracking via seq_trace" do
    test "replaces sleep with cross-process call block when traced process calls a GenServer" do
      shipper = start_shipper(flush_interval_ms: 50)
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:shipped, batch})
        :ok
      end)

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      # Start a simple GenServer that the traced process will call
      {:ok, target_server} =
        Agent.start_link(fn -> 0 end, name: :"TestAgent_#{System.unique_integer([:positive])}")

      # Start SeqTraceRouter
      seq_trace_router =
        start_supervised!(FlameOn.Client.SeqTraceRouter, id: :test_seq_trace_router)

      seq_trace_label = :erlang.unique_integer([:positive, :monotonic])

      # Spawn target that waits for tracing to be set up before doing work
      target =
        spawn(fn ->
          receive do
            :go ->
              # Set seq_trace token (normally done by Collector.handle_telemetry)
              :seq_trace.set_token(:label, seq_trace_label)
              :seq_trace.set_token(:send, true)
              :seq_trace.set_token(:receive, true)
              :seq_trace.set_token(:timestamp, true)

              # Make a GenServer.call to the Agent — this is the cross-process call
              Agent.get(target_server, fn state ->
                Process.sleep(10)
                state
              end)
          end
        end)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "cross_process_test",
        trace_id: "abc-123",
        threshold_us: 0
      }

      {:ok, _session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.001,
          seq_trace_label: seq_trace_label,
          seq_trace_router: seq_trace_router
        )

      # Now that tracing is active, trigger the work
      send(target, :go)

      assert_receive {:shipped, [trace_data]}, 5000

      # The shipped samples should contain a CALL entry for the Agent
      call_samples =
        Enum.filter(trace_data.samples, fn sample ->
          String.contains?(sample.stack_path, "CALL")
        end)

      assert length(call_samples) > 0,
             "Expected cross-process CALL block in samples, got: #{inspect(Enum.map(trace_data.samples, & &1.stack_path))}"

      # Cleanup
      Agent.stop(target_server)
    end

    test "cross-process call block includes the registered name of the target process" do
      shipper = start_shipper(flush_interval_ms: 50)
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:shipped, batch})
        :ok
      end)

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      agent_name = :"TestNamedAgent_#{System.unique_integer([:positive])}"
      {:ok, target_server} = Agent.start_link(fn -> 0 end, name: agent_name)

      # Reuse the same router from the first test (ETS table is shared)
      seq_trace_router =
        start_supervised!(FlameOn.Client.SeqTraceRouter, id: :test_seq_trace_router_named)

      seq_trace_label = :erlang.unique_integer([:positive, :monotonic])

      target =
        spawn(fn ->
          receive do
            :go ->
              :seq_trace.set_token(:label, seq_trace_label)
              :seq_trace.set_token(:send, true)
              :seq_trace.set_token(:receive, true)
              :seq_trace.set_token(:timestamp, true)

              Agent.get(target_server, fn state ->
                Process.sleep(10)
                state
              end)
          end
        end)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "named_process_test",
        trace_id: "abc-456",
        threshold_us: 0
      }

      {:ok, _session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.001,
          seq_trace_label: seq_trace_label,
          seq_trace_router: seq_trace_router
        )

      send(target, :go)

      assert_receive {:shipped, [trace_data]}, 5000

      call_sample =
        Enum.find(trace_data.samples, fn sample ->
          String.contains?(sample.stack_path, "CALL")
        end)

      assert call_sample != nil,
             "Expected cross-process CALL block, got: #{inspect(Enum.map(trace_data.samples, & &1.stack_path))}"

      assert String.contains?(call_sample.stack_path, inspect(agent_name)),
             "Expected agent name #{inspect(agent_name)} in stack path, got: #{call_sample.stack_path}"

      Agent.stop(target_server)
    end

    test "uses callback module name for unnamed GenServer processes" do
      shipper = start_shipper(flush_interval_ms: 50)
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:shipped, batch})
        :ok
      end)

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      # Start an unnamed Agent (no registered name)
      {:ok, target_server} = Agent.start_link(fn -> 0 end)

      seq_trace_router =
        start_supervised!(FlameOn.Client.SeqTraceRouter, id: :test_seq_trace_router_unnamed)

      seq_trace_label = :erlang.unique_integer([:positive, :monotonic])

      target =
        spawn(fn ->
          receive do
            :go ->
              :seq_trace.set_token(:label, seq_trace_label)
              :seq_trace.set_token(:send, true)
              :seq_trace.set_token(:receive, true)
              :seq_trace.set_token(:timestamp, true)

              Agent.get(target_server, fn state ->
                Process.sleep(10)
                state
              end)
          end
        end)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "unnamed_process_test",
        trace_id: "abc-789",
        threshold_us: 0
      }

      {:ok, _session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.001,
          seq_trace_label: seq_trace_label,
          seq_trace_router: seq_trace_router
        )

      send(target, :go)

      assert_receive {:shipped, [trace_data]}, 5000

      call_sample =
        Enum.find(trace_data.samples, fn sample ->
          String.contains?(sample.stack_path, "CALL")
        end)

      assert call_sample != nil,
             "Expected cross-process CALL block, got: #{inspect(Enum.map(trace_data.samples, & &1.stack_path))}"

      # Should show the Agent callback module, not "<process>"
      refute String.contains?(call_sample.stack_path, "<process>"),
             "Expected module name instead of <process>, got: #{call_sample.stack_path}"

      Agent.stop(target_server)
    end
  end

  describe "session terminates after finalization" do
    test "session process terminates after finalize_and_ship" do
      shipper = start_shipper(flush_interval_ms: 50)

      target =
        spawn(fn ->
          Process.sleep(100)
        end)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "terminate_test",
        trace_id: "abc-123",
        threshold_us: 0
      }

      {:ok, session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.01
        )

      ref = Process.monitor(session)
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 5000
    end
  end
end
