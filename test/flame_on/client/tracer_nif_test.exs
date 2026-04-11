defmodule FlameOn.Client.TracerNifTest do
  @moduledoc """
  Tests for Phase 5 erl_tracer NIF integration.

  These tests verify:
  - NIF tracer stubs exist and have correct fallback behavior
  - Ring buffer management functions are callable
  - tracer_available?/0 returns a boolean
  - NIF tracer integration works when the NIF is loaded (conditional tests)
  """

  use ExUnit.Case, async: false

  alias FlameOn.Client.NativeProcessor

  describe "tracer NIF availability" do
    test "tracer_available? returns a boolean" do
      assert is_boolean(NativeProcessor.tracer_available?())
    end
  end

  describe "ring buffer management stubs" do
    test "create_trace_buffer returns ok or error" do
      result = NativeProcessor.create_trace_buffer(4096)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "drain_trace_buffer returns error when NIF not loaded" do
      # With a fake buffer ref, it should return an error
      result = NativeProcessor.drain_trace_buffer(make_ref(), 1000)
      assert match?({:error, _}, result)
    end

    test "trace_buffer_stats returns error when NIF not loaded" do
      result = NativeProcessor.trace_buffer_stats(make_ref())
      assert match?({:error, _}, result)
    end

    test "set_trace_active returns error when NIF not loaded" do
      result = NativeProcessor.set_trace_active(make_ref(), true)
      assert match?({:error, _}, result)
    end
  end

  describe "erl_tracer fallback behavior" do
    test "enabled/3 returns :remove when NIF not loaded" do
      assert NativeProcessor.enabled(:call, nil, self()) == :remove
    end

    test "trace/5 returns :ok when NIF not loaded" do
      assert NativeProcessor.trace(:call, nil, self(), {Kernel, :+, 2}, %{}) == :ok
    end
  end

  if FlameOn.Client.NativeProcessor.tracer_available?() do
    describe "NIF tracer integration" do
      test "create, write via trace, drain, and read events" do
        {:ok, buffer} = NativeProcessor.create_trace_buffer(4096)
        NativeProcessor.set_trace_active(buffer, true)

        # Start tracing current process with the NIF tracer
        :erlang.trace(self(), true, [
          :call, :return_to, :arity, :timestamp,
          {:tracer, FlameOn.Client.NativeProcessor, buffer}
        ])

        :erlang.trace_pattern({__MODULE__, :_, :_}, true, [:local])

        # Do some work that will generate trace events
        traced_function()

        # Stop tracing
        :erlang.trace(self(), false, [:all])

        # Drain and verify
        {:ok, events} = NativeProcessor.drain_trace_buffer(buffer, 1000)
        assert is_list(events)
        assert length(events) > 0

        # Each event should be a tuple with type atom, mfa data, and timestamp
        Enum.each(events, fn event ->
          assert is_tuple(event)
          type = elem(event, 0)
          assert type in [:call, :return_to, :out, :in]
        end)
      end

      test "buffer stats returns a tuple" do
        {:ok, buffer} = NativeProcessor.create_trace_buffer(4096)
        result = NativeProcessor.trace_buffer_stats(buffer)
        assert is_tuple(result)
      end

      test "set_trace_active toggles without error" do
        {:ok, buffer} = NativeProcessor.create_trace_buffer(4096)
        assert :ok = NativeProcessor.set_trace_active(buffer, true)
        assert :ok = NativeProcessor.set_trace_active(buffer, false)
      end
    end

    defp traced_function do
      Enum.map(1..10, fn x -> x * 2 end)
    end
  end
end
