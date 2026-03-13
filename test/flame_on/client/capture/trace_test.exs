defmodule FlameOn.Client.Capture.TraceTest do
  use ExUnit.Case, async: false

  alias FlameOn.Client.Capture.Trace

  describe "start_trace/2" do
    test "starts tracing on a pid and delivers call trace messages" do
      tracer = self()

      pid =
        spawn(fn ->
          receive do
            # Use apply/3 to prevent compiler inlining
            :go -> apply(String, :length, ["hello"])
          end
        end)

      assert :ok = Trace.start_trace(pid, tracer)

      send(pid, :go)

      # With :arity flag, call traces are 5-tuples: {:trace_ts, pid, :call, mfa, timestamp}
      assert_receive {:trace_ts, ^pid, :call, _mfa, _timestamp}, 1000

      Trace.stop_trace(pid)
    end

    test "delivers return_to trace messages" do
      tracer = self()

      pid =
        spawn(fn ->
          receive do
            :go -> apply(String, :length, ["hello"])
          end
        end)

      assert :ok = Trace.start_trace(pid, tracer)

      send(pid, :go)

      assert_receive {:trace_ts, ^pid, :return_to, _mfa, _timestamp}, 1000

      Trace.stop_trace(pid)
    end

    test "delivers scheduling trace messages" do
      tracer = self()

      pid =
        spawn(fn ->
          receive do
            :go ->
              Process.sleep(10)
          end
        end)

      assert :ok = Trace.start_trace(pid, tracer)

      send(pid, :go)

      # :out means process was scheduled out
      assert_receive {:trace_ts, ^pid, :out, _mfa, _timestamp}, 1000

      Trace.stop_trace(pid)
    end

    test "trace messages include erlang timestamps" do
      tracer = self()

      pid =
        spawn(fn ->
          receive do
            :go -> apply(String, :length, ["hello"])
          end
        end)

      assert :ok = Trace.start_trace(pid, tracer)

      send(pid, :go)

      # Any trace_ts message should have a timestamp tuple
      assert_receive {:trace_ts, ^pid, _type, _info, {mega, secs, micro}}, 1000
      assert is_integer(mega)
      assert is_integer(secs)
      assert is_integer(micro)

      Trace.stop_trace(pid)
    end

    test "traces functions in modules loaded after trace starts" do
      tracer = self()

      # Define a module dynamically so it's guaranteed to not be loaded yet
      module_code = """
      defmodule FlameOn.Client.Capture.TraceTest.LazyModule do
        def work, do: :ok
      end
      """

      # Purge if it exists from a previous test run
      :code.purge(FlameOn.Client.Capture.TraceTest.LazyModule)
      :code.delete(FlameOn.Client.Capture.TraceTest.LazyModule)

      pid =
        spawn(fn ->
          receive do
            :go ->
              # Compile and call the module — this triggers on_load
              Code.compile_string(module_code)
              apply(FlameOn.Client.Capture.TraceTest.LazyModule, :work, [])
          end
        end)

      assert :ok = Trace.start_trace(pid, tracer)
      send(pid, :go)

      # We should receive a :call trace for the dynamically loaded module
      assert_receive {:trace_ts, ^pid, :call, {FlameOn.Client.Capture.TraceTest.LazyModule, :work, 0}, _timestamp}, 2000

      Trace.stop_trace(pid)
    end
  end

  describe "stop_trace/1" do
    test "stops tracing on a pid" do
      tracer = self()

      pid =
        spawn(fn ->
          receive do
            :go -> :ok
          after
            5000 -> :timeout
          end
        end)

      Trace.start_trace(pid, tracer)

      # Drain any existing trace messages
      flush_trace_messages(pid)

      assert :ok = Trace.stop_trace(pid)

      send(pid, :go)

      # Should not receive any trace messages after stop
      refute_receive {:trace_ts, ^pid, _, _, _}, 100
    end
  end

  defp flush_trace_messages(pid) do
    receive do
      {:trace_ts, ^pid, _, _, _} -> flush_trace_messages(pid)
      {:trace_ts, ^pid, _, _, _, _} -> flush_trace_messages(pid)
    after
      50 -> :ok
    end
  end
end
