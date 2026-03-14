defmodule FlameOn.Client.TraceSessionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
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
          ingest_token: "test-key"
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
