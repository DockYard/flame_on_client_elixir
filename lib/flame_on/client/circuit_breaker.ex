defmodule FlameOn.Client.CircuitBreaker do
  @moduledoc """
  A persistent_term-based killswitch that disables all new traces when
  memory pressure is detected. Reading a persistent_term is ~nanoseconds,
  so the cost of checking on every telemetry event is negligible.
  """

  @key :flame_on_tracing_disabled

  def init do
    :persistent_term.put(@key, false)
    :ok
  end

  def disabled? do
    :persistent_term.get(@key, false)
  end

  def disable! do
    :persistent_term.put(@key, true)
  end

  def enable! do
    :persistent_term.put(@key, false)
  end
end
