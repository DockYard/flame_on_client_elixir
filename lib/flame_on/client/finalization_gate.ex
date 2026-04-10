defmodule FlameOn.Client.FinalizationGate do
  @moduledoc """
  Atomic counter semaphore that limits the number of TraceSession processes
  performing post-processing simultaneously. Prevents concurrent finalizations
  from consuming excessive memory.
  """

  @key :flame_on_finalization_count

  def init(max_concurrent) do
    :persistent_term.put(:flame_on_max_finalizations, max_concurrent)

    :counters.new(1, [:atomics])
    |> then(&:persistent_term.put(@key, &1))
  end

  def acquire do
    counter = :persistent_term.get(@key)
    max = :persistent_term.get(:flame_on_max_finalizations)
    current = :counters.get(counter, 1)

    if current < max do
      :counters.add(counter, 1, 1)
      :ok
    else
      :full
    end
  end

  def release do
    counter = :persistent_term.get(@key)
    :counters.sub(counter, 1, 1)
    :ok
  end
end
