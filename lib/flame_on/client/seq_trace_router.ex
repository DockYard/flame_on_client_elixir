defmodule FlameOn.Client.SeqTraceRouter do
  use GenServer

  @table __MODULE__

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Register a seq_trace label to forward messages to the given session PID.
  Writes directly to ETS — no message passing overhead.
  """
  def register(label, session_pid) do
    :ets.insert(@table, {label, session_pid})
    :ok
  end

  @doc """
  Unregister a seq_trace label. Writes directly to ETS.
  """
  def unregister(label) do
    :ets.delete(@table, label)
    :ok
  end

  @doc """
  Flush the router's mailbox. Returns after all pending messages have been processed.
  This ensures any in-flight seq_trace messages have been forwarded to sessions.
  """
  def flush(router) do
    GenServer.call(router, :flush)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :seq_trace.set_system_tracer(self())
    {:ok, %{}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:seq_trace, label, _info, _timestamp} = msg, state) do
    case :ets.lookup(@table, label) do
      [{^label, session_pid}] -> send(session_pid, msg)
      [] -> :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
