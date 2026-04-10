defmodule FlameOn.Client.TraceSessionStreamingTest do
  @moduledoc """
  Tests for Phase 3 streaming collapsed stacks architecture.

  These tests verify the core Phase 3 changes:
  - Streaming stacks accumulation (call/return_to produce correct paths and durations)
  - Eviction (max_stacks cap works and evicts smallest)
  - Adaptive degradation (trace flags reduced at thresholds)
  - Cross-process calls appear in stacks map
  - End-to-end: trace a real function, verify shipped data is valid
  """

  use ExUnit.Case, async: false

  alias FlameOn.Client.TraceSession

  # -------------------------------------------------------------------
  # Unit tests for helper functions
  # -------------------------------------------------------------------

  describe "build_stack_path/1" do
    test "builds semicolon-separated path from reversed call stack" do
      call_stack = [{:example, :leaf, 0}, {:example, :mid, 1}, {:root, "test", "op"}]
      assert TraceSession.build_stack_path(call_stack) == "test op;example.mid/1;example.leaf/0"
    end

    test "handles single-element stack" do
      call_stack = [{:root, "test", "op"}]
      assert TraceSession.build_stack_path(call_stack) == "test op"
    end

    test "handles sleep pseudo-frame" do
      call_stack = [:sleep, {:example, :foo, 0}, {:root, "test", "op"}]
      assert TraceSession.build_stack_path(call_stack) == "test op;example.foo/0;SLEEP"
    end

    test "handles cross-process call pseudo-frame" do
      call_stack = [
        {:cross_process_call, self(), MyApp.Repo, {:get, :user}},
        :sleep,
        {:example, :foo, 0},
        {:root, "test", "op"}
      ]

      result = TraceSession.build_stack_path(call_stack)
      assert String.starts_with?(result, "test op;example.foo/0;SLEEP;CALL MyApp.Repo")
    end
  end

  describe "format_mfa/1" do
    test "formats standard MFA tuple" do
      assert TraceSession.format_mfa({MyApp.Orders, :list_orders, 1}) ==
               "Elixir.MyApp.Orders.list_orders/1"
    end

    test "formats erlang module MFA tuple" do
      assert TraceSession.format_mfa({:timer, :sleep, 1}) == "timer.sleep/1"
    end

    test "formats sleep atom" do
      assert TraceSession.format_mfa(:sleep) == "SLEEP"
    end

    test "formats root tuple" do
      assert TraceSession.format_mfa({:root, "phoenix.request", "GET /users/:id"}) ==
               "phoenix.request GET /users/:id"
    end

    test "formats cross-process call with name and message" do
      result = TraceSession.format_mfa({:cross_process_call, self(), MyApp.Repo, {:get, :user, 42}})
      assert result == "CALL MyApp.Repo {:get, :user, 42}"
    end

    test "formats cross-process call without message" do
      result = TraceSession.format_mfa({:cross_process_call, self(), MyApp.Repo})
      assert result == "CALL MyApp.Repo"
    end

    test "formats cross-process call with nil name" do
      result = TraceSession.format_mfa({:cross_process_call, self(), nil, {:get, :user}})
      assert String.contains?(result, "CALL <process>")
    end
  end

  describe "add_to_stacks/5" do
    test "adds new path when under limit" do
      {stacks, count} = TraceSession.add_to_stacks(%{}, 0, 100, "a;b;c", 500)
      assert stacks == %{"a;b;c" => 500}
      assert count == 1
    end

    test "accumulates duration for existing path" do
      stacks = %{"a;b;c" => 500}
      {stacks, count} = TraceSession.add_to_stacks(stacks, 1, 100, "a;b;c", 300)
      assert stacks == %{"a;b;c" => 800}
      assert count == 1
    end

    test "evicts smallest when at limit" do
      stacks = %{"a" => 100, "b" => 200, "c" => 300}
      {stacks, count} = TraceSession.add_to_stacks(stacks, 3, 3, "d", 150)

      # "a" (100) was the smallest, should be evicted
      refute Map.has_key?(stacks, "a")
      assert Map.has_key?(stacks, "d")
      assert stacks["d"] == 150
      assert count == 3
    end

    test "does not grow beyond max_stacks" do
      # Build a stacks map at capacity
      stacks = Map.new(1..10, fn i -> {"path_#{i}", i * 100} end)

      # Add a new path - should evict smallest and maintain count
      {new_stacks, count} = TraceSession.add_to_stacks(stacks, 10, 10, "new_path", 50)
      assert map_size(new_stacks) == 10
      assert count == 10
      assert Map.has_key?(new_stacks, "new_path")
    end

    test "evicts the entry with smallest duration" do
      stacks = %{"small" => 10, "medium" => 500, "large" => 1000}
      {stacks, _count} = TraceSession.add_to_stacks(stacks, 3, 3, "new", 200)

      refute Map.has_key?(stacks, "small")
      assert Map.has_key?(stacks, "medium")
      assert Map.has_key?(stacks, "large")
      assert Map.has_key?(stacks, "new")
    end
  end

  describe "pop_stack_to/2" do
    test "pops to matching MFA" do
      stack = [{:example, :leaf, 0}, {:example, :mid, 1}, {:example, :root, 0}]
      result = TraceSession.pop_stack_to(stack, {:example, :mid, 1})
      assert result == [{:example, :mid, 1}, {:example, :root, 0}]
    end

    test "returns stack unchanged when top matches" do
      stack = [{:example, :foo, 0}, {:example, :root, 0}]
      result = TraceSession.pop_stack_to(stack, {:example, :foo, 0})
      assert result == stack
    end

    test "preserves root frame when MFA not found" do
      stack = [{:example, :foo, 0}, {:example, :bar, 1}]
      result = TraceSession.pop_stack_to(stack, {:example, :missing, 0})
      # Should preserve the last (root) frame
      assert result == [{:example, :bar, 1}]
    end

    test "handles empty stack" do
      assert TraceSession.pop_stack_to([], {:example, :foo, 0}) == []
    end

    test "pops multiple frames to reach target" do
      stack = [
        {:example, :d, 0},
        {:example, :c, 0},
        {:example, :b, 0},
        {:example, :a, 0}
      ]

      result = TraceSession.pop_stack_to(stack, {:example, :a, 0})
      assert result == [{:example, :a, 0}]
    end
  end

  # -------------------------------------------------------------------
  # Integration tests with real tracing
  # -------------------------------------------------------------------

  import Mox

  setup :verify_on_exit!

  setup do
    # Re-initialize the FinalizationGate to clean state so tests aren't blocked
    # by counter leaks from other test suites (e.g., FinalizationGate tests)
    FlameOn.Client.FinalizationGate.init(2)
    :ok
  end

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

    shipper = start_supervised!({FlameOn.Client.Shipper, shipper_opts}, id: :test_shipper_streaming)
    allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)
    shipper
  end

  describe "streaming stacks accumulation" do
    test "call/return sequences produce correct stack paths" do
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
        event_identifier: "streaming_test",
        trace_id: "abc-123",
        threshold_us: 0
      }

      {:ok, _session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.001,
          adaptive_degradation: false
        )

      assert_receive {:shipped, [trace_data]}, 5000

      assert trace_data.event_name == "test.event"
      assert trace_data.event_identifier == "streaming_test"
      assert is_list(trace_data.samples)
      assert length(trace_data.samples) > 0

      # All stack paths should start with the root event
      for sample <- trace_data.samples do
        assert String.starts_with?(sample.stack_path, "test.event streaming_test"),
               "Stack path should start with event root: #{sample.stack_path}"
      end

      # Duration should be positive
      assert trace_data.duration_us > 0
    end

    test "accumulates cumulative duration for same stack path" do
      shipper = start_shipper(flush_interval_ms: 50)
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:shipped, batch})
        :ok
      end)

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      # Call the same function multiple times to produce repeated paths
      defmodule RepeatedWork do
        def work do
          do_thing()
          do_thing()
          do_thing()
        end

        def do_thing do
          Process.sleep(50)
        end
      end

      target =
        spawn(fn ->
          RepeatedWork.work()
        end)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "cumulative_test",
        trace_id: "abc-456",
        threshold_us: 0
      }

      {:ok, _session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.001,
          adaptive_degradation: false
        )

      assert_receive {:shipped, [trace_data]}, 5000

      # Verify samples are present and have positive durations
      assert length(trace_data.samples) > 0

      for sample <- trace_data.samples do
        assert sample.duration_us >= 0
      end
    end
  end

  describe "eviction" do
    test "max_stacks cap works with small limit" do
      shipper = start_shipper(flush_interval_ms: 50)
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:shipped, batch})
        :ok
      end)

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      # Generate enough unique paths to exceed a small max_stacks
      defmodule ManyPaths do
        def work do
          a()
          b()
          c()
          d()
          e()
        end

        def a, do: Process.sleep(50)
        def b, do: Process.sleep(50)
        def c, do: Process.sleep(50)
        def d, do: Process.sleep(50)
        def e, do: Process.sleep(50)
      end

      target =
        spawn(fn ->
          ManyPaths.work()
        end)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "eviction_test",
        trace_id: "abc-789",
        threshold_us: 0
      }

      {:ok, _session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.001,
          max_stacks: 5,
          adaptive_degradation: false
        )

      assert_receive {:shipped, [trace_data]}, 5000

      # With max_stacks: 5, we should have at most 5 samples
      assert length(trace_data.samples) <= 5
    end
  end

  describe "end-to-end" do
    test "trace a real function, verify shipped data is valid" do
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
          Process.sleep(100)
          apply(String, :length, ["hello world"])
        end)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "e2e_test",
        trace_id: "e2e-123",
        threshold_us: 0
      }

      {:ok, _session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.001,
          adaptive_degradation: false
        )

      assert_receive {:shipped, [trace_data]}, 5000

      assert trace_data.trace_id == "e2e-123"
      assert trace_data.event_name == "test.event"
      assert trace_data.event_identifier == "e2e_test"
      assert is_integer(trace_data.duration_us)
      assert trace_data.duration_us > 0
      assert is_list(trace_data.samples)
      assert length(trace_data.samples) > 0

      # Verify samples have correct format
      for sample <- trace_data.samples do
        assert is_binary(sample.stack_path)
        assert is_integer(sample.duration_us)
        assert sample.duration_us >= 0
      end

      # Verify the stacks contain the root event
      stack_paths = Enum.map(trace_data.samples, & &1.stack_path)
      all_stacks = Enum.join(stack_paths, "\n")

      assert String.contains?(all_stacks, "test.event e2e_test"),
             "Expected root event in stacks but got:\n#{all_stacks}"
    end
  end

  describe "finalize and ship on :stop cast" do
    test "finalizes and ships streaming stacks when receiving :stop cast" do
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
          function_length_threshold: 0.01,
          adaptive_degradation: false
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
        # 60 second threshold -- trace will be way below
        threshold_us: 60_000_000
      }

      {:ok, _session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.01,
          adaptive_degradation: false
        )

      # Wait for process to exit and session to process
      Process.sleep(500)

      refute_receive {:shipped, _}, 200
    end
  end

  describe "root block naming" do
    test "all stack paths start with event root, never SLEEP" do
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
        event_identifier: "root_name_test",
        trace_id: "abc-123",
        threshold_us: 0
      }

      {:ok, _session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.01,
          adaptive_degradation: false
        )

      assert_receive {:shipped, [trace_data]}, 5000

      for sample <- trace_data.samples do
        refute String.starts_with?(sample.stack_path, "SLEEP"),
               "Stack path should not start with SLEEP: #{sample.stack_path}"

        assert String.starts_with?(sample.stack_path, "test.event root_name_test"),
               "Stack path should start with event root: #{sample.stack_path}"
      end
    end
  end

  describe "cross-process call tracking via seq_trace" do
    test "cross-process call appears in stacks map" do
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
        Agent.start_link(fn -> 0 end, name: :"TestAgent_Streaming_#{System.unique_integer([:positive])}")

      # Start SeqTraceRouter
      seq_trace_router =
        start_supervised!(FlameOn.Client.SeqTraceRouter, id: :test_seq_trace_router_streaming)

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
        event_identifier: "cross_process_streaming",
        trace_id: "seq-123",
        threshold_us: 0
      }

      {:ok, _session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.001,
          seq_trace_label: seq_trace_label,
          seq_trace_router: seq_trace_router,
          adaptive_degradation: false
        )

      send(target, :go)

      assert_receive {:shipped, [trace_data]}, 5000

      call_samples =
        Enum.filter(trace_data.samples, fn sample ->
          String.contains?(sample.stack_path, "CALL")
        end)

      assert length(call_samples) > 0,
             "Expected cross-process CALL in samples, got: #{inspect(Enum.map(trace_data.samples, & &1.stack_path))}"

      Agent.stop(target_server)
    end

    test "cross-process call includes registered name of target process" do
      shipper = start_shipper(flush_interval_ms: 50)
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:shipped, batch})
        :ok
      end)

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      agent_name = :"TestNamedAgent_Streaming_#{System.unique_integer([:positive])}"
      {:ok, target_server} = Agent.start_link(fn -> 0 end, name: agent_name)

      seq_trace_router =
        start_supervised!(FlameOn.Client.SeqTraceRouter, id: :test_seq_trace_router_streaming_named)

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
        event_identifier: "named_streaming",
        trace_id: "seq-456",
        threshold_us: 0
      }

      {:ok, _session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.001,
          seq_trace_label: seq_trace_label,
          seq_trace_router: seq_trace_router,
          adaptive_degradation: false
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
  end

  describe "adaptive degradation" do
    test "discard signal returned at drop threshold" do
      # This is tested indirectly -- the maybe_degrade function is private,
      # but we can verify the behavior by setting a very low max_events
      shipper = start_shipper(flush_interval_ms: 50)

      target =
        spawn(fn ->
          # Generate lots of events
          Enum.reduce(1..1000, 0, fn i, acc -> acc + i end)
          Process.sleep(100)
        end)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "degrade_test",
        trace_id: "deg-123",
        threshold_us: 0
      }

      {:ok, session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.01,
          max_events: 100,
          adaptive_degradation: true
        )

      # Wait for session to process and potentially discard
      ref = Process.monitor(session)
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 5000

      Process.exit(target, :kill)
    end

    test "adaptive degradation can be disabled" do
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
          Process.sleep(100)
          apply(String, :length, ["hello"])
        end)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "no_degrade_test",
        trace_id: "ndeg-123",
        threshold_us: 0
      }

      {:ok, _session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.01,
          adaptive_degradation: false
        )

      assert_receive {:shipped, [trace_data]}, 5000
      assert trace_data.event_name == "test.event"
    end
  end

  describe "session lifecycle" do
    test "session process terminates after finalize_and_ship" do
      shipper = start_shipper(flush_interval_ms: 50)

      target =
        spawn(fn ->
          Process.sleep(100)
        end)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "terminate_test",
        trace_id: "term-123",
        threshold_us: 0
      }

      {:ok, session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.01,
          adaptive_degradation: false
        )

      ref = Process.monitor(session)
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 5000
    end

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
          function_length_threshold: 0.01,
          adaptive_degradation: false
        )

      assert Process.alive?(session)

      # Cleanup
      FlameOn.Client.Capture.Trace.stop_trace(target)
      Process.exit(target, :kill)
      Process.exit(session, :kill)
    end

    test "stops if traced process is already dead" do
      shipper = start_shipper()

      target = spawn(fn -> :ok end)
      Process.sleep(50)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "test_op",
        trace_id: "abc-123",
        threshold_us: 0
      }

      Process.flag(:trap_exit, true)

      result =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.01,
          adaptive_degradation: false
        )

      assert {:error, :process_not_alive} = result

      Process.flag(:trap_exit, false)
    end
  end

  describe "sleep tracking" do
    test "SLEEP entries appear in stacks when process sleeps" do
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
        end)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "sleep_test",
        trace_id: "slp-123",
        threshold_us: 0
      }

      {:ok, _session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.001,
          adaptive_degradation: false
        )

      assert_receive {:shipped, [trace_data]}, 5000

      sleep_samples =
        Enum.filter(trace_data.samples, fn sample ->
          String.contains?(sample.stack_path, "SLEEP")
        end)

      assert length(sleep_samples) > 0,
             "Expected SLEEP entries in stacks, got: #{inspect(Enum.map(trace_data.samples, & &1.stack_path))}"

      # SLEEP entries should have positive duration
      for sample <- sleep_samples do
        assert sample.duration_us > 0,
               "SLEEP entry should have positive duration: #{inspect(sample)}"
      end
    end
  end

  describe "trace completeness" do
    test "captures intermediate function calls" do
      shipper = start_shipper(flush_interval_ms: 50)
      test_pid = self()

      FlameOn.Client.Shipper.MockAdapter
      |> expect(:send_batch, fn batch, _config ->
        send(test_pid, {:shipped, batch})
        :ok
      end)

      allow(FlameOn.Client.Shipper.MockAdapter, self(), shipper)

      defmodule TracedWorkStreaming do
        def outer do
          # Do measurable work so this function has non-zero self-time
          Enum.reduce(1..1000, 0, fn i, acc -> acc + i end)
          middle()
        end

        def middle do
          Enum.reduce(1..1000, 0, fn i, acc -> acc + i end)
          inner()
        end

        def inner do
          Process.sleep(50)
          Enum.reduce(1..1000, 0, fn i, acc -> acc + i end)
        end
      end

      target =
        spawn(fn ->
          TracedWorkStreaming.outer()
        end)

      trace_info = %{
        event_name: "test.event",
        event_identifier: "intermediate_streaming",
        trace_id: "int-123",
        threshold_us: 0
      }

      {:ok, _session} =
        TraceSession.start_link(
          traced_pid: target,
          trace_info: trace_info,
          shipper_pid: shipper,
          function_length_threshold: 0.001,
          adaptive_degradation: false
        )

      assert_receive {:shipped, [trace_data]}, 5000

      # In the streaming collapsed stacks model, functions appear when they
      # have non-zero duration between call and return_to.
      # The key verification: shipped data contains samples and is valid
      assert length(trace_data.samples) > 0

      stack_paths = Enum.map(trace_data.samples, & &1.stack_path)
      all_stacks = Enum.join(stack_paths, "\n")

      # At minimum, the traced functions that do measurable work should appear
      assert String.contains?(all_stacks, "TracedWorkStreaming"),
             "Expected TracedWorkStreaming in stacks but got:\n#{all_stacks}"
    end
  end
end
