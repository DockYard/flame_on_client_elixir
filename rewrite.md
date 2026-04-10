# FlameOn Client Architecture Rewrite

## Context

This document describes the complete architecture rewrite of the FlameOn client library for production memory safety. It is informed by:

- **research.md** — the production incident analysis and comparative study of 9 tracing tools
- **The streaming data systems research** — formal framework for memory-bounded streaming architectures
- **Direct source code analysis** of the current FlameOn client (19 modules, ~3,500 LOC)

The rewrite is organized in three phases, each independently deployable. Phase 4 (Zig NIF for post-processing) is out of scope for this document but the architecture is designed to accommodate it.

---

## Design Principles

These are non-negotiable invariants. Every data structure, every process, every buffer in the system must satisfy all of them.

1. **Every in-memory data structure must have a bound that is a function of configuration — not input size.** If you cannot express the bound, you must externalize, window/expire, approximate, or drop.

2. **Backpressure is a first-class contract.** When downstream is slower than upstream, upstream must slow down or shed load. Silent unbounded buffering is never acceptable.

3. **The host application's stability takes absolute priority over trace fidelity.** It is always better to lose a trace than to OOM the application. Graceful degradation (reduced fidelity) is preferred over hard drops, but hard drops are preferred over unbounded growth.

4. **Capture and computation are separate concerns.** Raw trace events are captured in a bounded buffer. Post-processing happens after capture ends, with its own time and memory budget. A slow or failed post-processing step cannot affect capture of subsequent traces.

---

## Current Architecture (What Exists)

```
Telemetry Event
  → Collector (GenServer, decides to sample)
    → TraceSessionSupervisor (DynamicSupervisor)
      → TraceSession (GenServer per trace)
        → erlang:trace messages arrive in GenServer mailbox
        → Each message creates a Block struct on a stack in GenServer state
        → On trace end: finalize_and_ship
          → Stack.finalize_stack (close unclosed blocks, compute durations)
          → CollapsedStacks.convert (walk Block tree → flat stack paths)
          → ProfileFilter.filter (remove small functions)
          → PprofEncoder.encode (protobuf)
          → Shipper.push (queue for gRPC delivery)
```

### Current Module Responsibilities

| Module | Purpose | State Size |
|--------|---------|------------|
| Collector | Orchestrate trace lifecycle, sampling, telemetry subscriptions | Small (active_traces map, ~10 entries) |
| TraceSession | Capture trace events, build Block tree, finalize and ship | **Unbounded** (Block tree grows with every function call) |
| Block | Data structure for a single function call with children | Per-instance small, but tree is recursive |
| Stack | Push/pop/finalize operations on the Block stack | Operates on TraceSession's stack |
| Trace | Thin wrapper around erlang:trace/3 | Stateless |
| CollapsedStacks | Convert Block tree → flat collapsed stacks | **Allocates O(N × depth²)** during walk |
| ProfileFilter | Filter small functions from collapsed stacks | **Allocates O(N × S²)** during build_inclusive_times |
| PprofEncoder | Encode to protobuf | O(N) — proportional to samples |
| Shipper | Buffer and batch-ship traces via gRPC | Bounded (max_buffer_size: 500) |
| SeqTraceRouter | Route seq_trace messages to correct TraceSession | Small (ETS table of label → pid) |
| TraceSessionSupervisor | DynamicSupervisor for TraceSession processes | Minimal |

### Where Memory Explodes

1. **TraceSession.state.stack**: Block tree grows with every `:call`/`:return_to` message. A 500ms request can generate 200K blocks. No cap existed before our Phase 1 fix.

2. **CollapsedStacks.walk/2**: Recursive walk with `ancestors ++ [function]` copies the ancestor list at every level. O(N × depth²) allocations. Fixed in Phase 1.

3. **ProfileFilter.build_inclusive_times/1**: `Enum.scan` with string concatenation creates N × S prefix strings. O(N × S²) allocations. Fixed in Phase 1.

4. **TraceSession GenServer mailbox**: erlang:trace sends messages faster than the GenServer can process them. The mailbox is an unbounded BEAM queue. No backpressure exists.

5. **Concurrent finalization**: Multiple TraceSession processes can finalize simultaneously, each consuming hundreds of MB. No concurrency limit exists.

---

## Phase 1: Prevent OOM (COMPLETE)

These fixes are already deployed. They are blunt instruments — hard cutoffs that discard data rather than degrade gracefully. They prevent the immediate OOM but are not the final architecture.

### What Was Done

1. **CollapsedStacks.walk/2** — Replaced `ancestors ++ [function]` (O(N) copy per call) with reversed accumulator prepend (O(1)). Path strings built only at leaf nodes.

2. **ProfileFilter.path_prefixes/1** — Replaced `Enum.scan` with eager string concatenation with `:binary.matches` + `binary_part`, creating sub-binary references instead of copies.

3. **max_events: 500,000** — TraceSession discards the entire trace if event count exceeds the limit. Configurable via `:flame_on_client, :max_events`.

4. **10-second finalization timeout** — `finalize_and_ship` wrapped in `Task.async` with `Task.yield(task, 10_000) || Task.shutdown(task)`. Traces that take too long to process are killed.

### Tradeoffs Accepted

- Legitimate large traces are silently discarded (max_events)
- The 10s timeout is not adaptive to system load
- binary_part sub-references hold parent binary in memory
- No backpressure — new traces still start regardless of system state
- No deduplication — the same failing endpoint can be profiled repeatedly

---

## Phase 2: Structural Bounds

Phase 2 adds the safety mechanisms that should have existed from the start. These are inspired by production patterns from OTel (persistent_term disable flag), Spandex (sync_threshold), Sentry (dedup with TTL), and recon_trace (mandatory limits).

### 2.1 System-Wide Disable Flag

**Module**: `FlameOn.Client.CircuitBreaker` (new)

A `persistent_term`-based killswitch that disables all new traces when memory pressure is detected. This is the OTel pattern.

```elixir
defmodule FlameOn.Client.CircuitBreaker do
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
```

**Integration point**: `Collector.handle_start_event` — before sampling, check `CircuitBreaker.disabled?()`. If true, return immediately. Cost: one `persistent_term` read (~nanoseconds).

**Trigger**: A periodic check (every 5 seconds) in a new `FlameOn.Client.MemoryWatcher` GenServer:

```
total_memory = :erlang.memory(:total)
if total_memory > config.max_memory_bytes do
  CircuitBreaker.disable!()
  Logger.warning("[FlameOn] Tracing disabled: memory #{div(total_memory, 1_048_576)}MB exceeds limit")
end

if total_memory < config.max_memory_bytes * 0.8 do
  CircuitBreaker.enable!()
  Logger.info("[FlameOn] Tracing re-enabled: memory dropped below threshold")
end
```

Hysteresis (enable at 80% of limit) prevents flapping.

**Config**:
- `:flame_on_client, :max_memory_bytes` — default: 80% of system memory (auto-detected via `:memsup` or `/proc/meminfo`)
- `:flame_on_client, :memory_check_interval_ms` — default: 5_000

### 2.2 Trace Deduplication

**Module**: `FlameOn.Client.TraceDedupe` (new)

ETS-based deduplication with configurable TTL window. Prevents profiling the same endpoint repeatedly during error cascades.

```elixir
defmodule FlameOn.Client.TraceDedupe do
  @table :flame_on_trace_dedupe

  def init do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    :ok
  end

  def should_trace?(event_identifier) do
    now = System.monotonic_time(:second)
    case :ets.lookup(@table, event_identifier) do
      [{_, last_traced}] when now - last_traced < window() -> false
      _ ->
        :ets.insert(@table, {event_identifier, now})
        true
    end
  end

  def sweep do
    now = System.monotonic_time(:second)
    cutoff = now - window()
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  end

  defp window, do: Application.get_env(:flame_on_client, :dedupe_window_seconds, 60)
end
```

**Integration point**: `Collector.handle_start_event` — after sampling check, before spawning TraceSession, call `TraceDedupe.should_trace?(event_identifier)`. This ensures at most one trace per endpoint per window.

**Sweep**: Periodic cleanup every 30 seconds (can piggyback on MemoryWatcher's timer).

**Config**:
- `:flame_on_client, :dedupe_window_seconds` — default: 60
- `:flame_on_client, :dedupe_enabled` — default: true

### 2.3 Concurrent Finalization Semaphore

**Module**: `FlameOn.Client.FinalizationGate` (new)

Limits the number of TraceSession processes performing post-processing simultaneously. This is the Spandex `sync_threshold` pattern adapted to FlameOn.

```elixir
defmodule FlameOn.Client.FinalizationGate do
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
```

**Integration point**: In `TraceSession.finalize_and_ship`:

```elixir
case FinalizationGate.acquire() do
  :ok ->
    try do
      do_finalize_and_ship(state)
    after
      FinalizationGate.release()
    end

  :full ->
    Logger.warning("[FlameOn] Finalization gate full, discarding trace")
    :ok
end
```

**Config**:
- `:flame_on_client, :max_concurrent_finalizations` — default: 2

### 2.4 Mailbox Depth Check

TraceSession should monitor its own mailbox depth and stop the trace early if messages are piling up faster than it can process them.

**Integration point**: In `TraceSession.handle_info` for trace messages, every 1000 events check the mailbox:

```elixir
if rem(state.event_count, 1000) == 0 do
  {:message_queue_len, len} = Process.info(self(), :message_queue_len)
  if len > @max_mailbox_depth do
    Logger.warning("[FlameOn] Trace mailbox overflow (#{len} pending), stopping trace")
    discard_trace(state)
  end
end
```

**Config**:
- `:flame_on_client, :max_mailbox_depth` — default: 50_000

### 2.5 Phase 2 Module Summary

| Module | Type | Purpose |
|--------|------|---------|
| `FlameOn.Client.CircuitBreaker` | New | persistent_term disable flag |
| `FlameOn.Client.MemoryWatcher` | New | Periodic memory check, triggers CircuitBreaker |
| `FlameOn.Client.TraceDedupe` | New | ETS dedup with TTL window |
| `FlameOn.Client.FinalizationGate` | New | Atomic counter semaphore for concurrent finalizations |
| `FlameOn.Client.Collector` | Modified | Check CircuitBreaker + TraceDedupe before starting traces |
| `FlameOn.Client.TraceSession` | Modified | Mailbox depth check, FinalizationGate acquire/release |
| `FlameOn.Client.Application` | Modified | Start MemoryWatcher, init CircuitBreaker/TraceDedupe/FinalizationGate |

### 2.6 Phase 2 Supervision Tree

```
FlameOn.Client.Application (Supervisor)
  ├── GRPC.Client.Supervisor
  ├── FlameOn.Client.MemoryWatcher          ← NEW
  ├── FlameOn.Client.SeqTraceRouter
  ├── FlameOn.Client.Shipper
  ├── FlameOn.Client.ErrorShipper
  ├── FlameOn.Client.TraceSessionSupervisor
  └── FlameOn.Client.Collector
```

CircuitBreaker, TraceDedupe, and FinalizationGate are initialized (ETS tables, persistent_terms) during Application.start before any children are spawned. They are not processes — they are shared state structures.

---

## Phase 3: Streaming Architecture

Phase 3 replaces the unbounded Block tree accumulation with a bounded streaming data structure. This is the fundamental architectural change that makes FlameOn structurally memory-safe.

### 3.1 The Core Change: Streaming Collapsed Stacks

Instead of building a complete Block tree in memory and converting it to collapsed stacks after the trace ends, **build the collapsed stacks incrementally during capture**.

#### Current Flow (Block Tree)

```
erlang:trace messages
  → push Block onto stack (accumulates)
  → push Block onto stack (accumulates)
  → ... (100K-1M times)
  → finalize_and_ship
    → Stack.finalize_stack (close all blocks)
    → CollapsedStacks.convert (walk entire tree, O(N × depth²))
    → ProfileFilter.filter (scan all samples, O(N × S²))
    → PprofEncoder.encode
    → Shipper.push
```

**Memory**: O(N) Block structs during capture + O(N × depth²) during post-processing.

#### New Flow (Streaming Collapsed Stacks)

```
erlang:trace messages
  → maintain a lightweight call stack (list of MFA tuples, not Block structs)
  → on :return_to, compute the stack path string from current stack
  → increment duration in a bounded map: %{stack_path => cumulative_us}
  → ... (100K-1M times, map size stays bounded by unique paths)
  → finalize_and_ship
    → map is already in collapsed stacks format
    → ProfileFilter.filter (scan map entries, typically 1K-10K, not 100K-1M)
    → PprofEncoder.encode
    → Shipper.push
```

**Memory**: O(P) where P = number of unique stack paths (typically 1K-10K). Independent of trace event count.

### 3.2 New TraceSession State

```elixir
%{
  # Identity
  traced_pid: pid,
  trace_info: map,
  shipper_pid: pid,

  # Configuration
  function_length_threshold: float,
  max_events: integer,
  max_stacks: integer,          # NEW: cap on unique stack paths

  # Capture state (replaces Block tree)
  call_stack: [mfa],            # NEW: lightweight list of current call chain
  stacks: %{binary => integer}, # NEW: stack_path => cumulative_us
  stack_count: integer,         # NEW: number of unique paths in map
  current_entry_time: integer,  # NEW: timestamp of most recent :call
  event_count: integer,

  # Cross-process tracking (unchanged)
  seq_trace_label: integer,
  seq_trace_router: pid,
  pending_calls: map,
  completed_calls: list,

  # Timing
  trace_start: integer,        # NEW: trace start timestamp
  trace_end: integer,          # NEW: trace end timestamp (set on finalize)

  # Scheduling state
  scheduled_out_at: integer    # NEW: timestamp when process was scheduled out
}
```

### 3.3 Trace Message Handling (New)

#### :call

```elixir
def handle_info({:trace_ts, _pid, :call, mfa, timestamp}, state) do
  if state.event_count >= state.max_events do
    discard_trace(state)
  else
    # Check mailbox every 1000 events
    state = maybe_check_mailbox(state)

    {:noreply, %{state |
      call_stack: [mfa | state.call_stack],
      current_entry_time: microseconds(timestamp),
      event_count: state.event_count + 1
    }}
  end
end
```

#### :return_to

```elixir
def handle_info({:trace_ts, _pid, :return_to, mfa, timestamp}, state) do
  if state.event_count >= state.max_events do
    discard_trace(state)
  else
    now = microseconds(timestamp)

    # Calculate duration of the function that just returned
    duration = now - state.current_entry_time

    # Build stack path from current call stack (already in reverse order)
    {stacks, stack_count} =
      if duration > 0 and state.call_stack != [] do
        path = build_stack_path(state.call_stack)
        add_to_stacks(state.stacks, state.stack_count, state.max_stacks, path, duration)
      else
        {state.stacks, state.stack_count}
      end

    # Pop the call stack back to the return target
    call_stack = pop_stack_to(state.call_stack, mfa)

    {:noreply, %{state |
      call_stack: call_stack,
      stacks: stacks,
      stack_count: stack_count,
      current_entry_time: now,
      event_count: state.event_count + 1
    }}
  end
end
```

#### :out / :in (scheduling)

```elixir
def handle_info({:trace_ts, _pid, :out, _mfa, timestamp}, state) do
  {:noreply, %{state |
    scheduled_out_at: microseconds(timestamp),
    event_count: state.event_count + 1
  }}
end

def handle_info({:trace_ts, _pid, :in, _mfa, timestamp}, state) do
  # Record sleep duration under a SLEEP pseudo-frame
  if state.scheduled_out_at do
    sleep_duration = microseconds(timestamp) - state.scheduled_out_at
    path = build_stack_path([:sleep | state.call_stack])
    {stacks, stack_count} =
      add_to_stacks(state.stacks, state.stack_count, state.max_stacks, path, sleep_duration)

    {:noreply, %{state |
      stacks: stacks,
      stack_count: stack_count,
      scheduled_out_at: nil,
      event_count: state.event_count + 1
    }}
  else
    {:noreply, %{state | event_count: state.event_count + 1}}
  end
end
```

### 3.4 Helper Functions

#### build_stack_path

Builds a semicolon-separated path from the call stack. The stack is in reverse order (most recent call first), so we reverse and format.

```elixir
defp build_stack_path(call_stack) do
  call_stack
  |> Enum.reverse()
  |> Enum.map(&format_mfa/1)
  |> Enum.join(";")
end

defp format_mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
defp format_mfa(:sleep), do: "SLEEP"
defp format_mfa({:root, name, id}), do: "#{name} #{id}"
defp format_mfa({:cross_process_call, _pid, name, msg}), do: "CALL #{name} #{msg}"
defp format_mfa(other), do: inspect(other)
```

#### add_to_stacks (bounded map with eviction)

```elixir
defp add_to_stacks(stacks, stack_count, max_stacks, path, duration) do
  case Map.fetch(stacks, path) do
    {:ok, existing} ->
      # Path already exists — just add duration. No growth.
      {Map.put(stacks, path, existing + duration), stack_count}

    :error when stack_count < max_stacks ->
      # New path, under limit — add it.
      {Map.put(stacks, path, duration), stack_count + 1}

    :error ->
      # New path, at limit — evict the smallest entry and add.
      {min_path, _min_dur} = Enum.min_by(stacks, fn {_k, v} -> v end)
      stacks = stacks |> Map.delete(min_path) |> Map.put(path, duration)
      {stacks, stack_count}
  end
end
```

**Note on eviction cost**: `Enum.min_by` is O(P) where P = map size. At max_stacks = 50K this is ~microseconds. If this becomes a bottleneck, replace with a min-heap or periodic batch eviction (evict bottom 10% when at 90% capacity).

### 3.5 Finalization (New — Dramatically Simpler)

```elixir
defp finalize_and_ship(state) do
  Trace.stop_trace(state.traced_pid)

  case FinalizationGate.acquire() do
    :full ->
      Logger.warning("[FlameOn] Finalization gate full, discarding trace")
      :ok

    :ok ->
      try do
        do_finalize_and_ship(state)
      after
        FinalizationGate.release()
      end
  end
end

defp do_finalize_and_ship(state) do
  trace = state.trace_info
  stacks = state.stacks

  total_duration = Enum.sum(Map.values(stacks))

  if total_duration >= trace.threshold_us and map_size(stacks) > 0 do
    # Convert map to sample list (already in collapsed stacks format!)
    samples = Enum.map(stacks, fn {path, duration} ->
      %{stack_path: path, duration_us: duration}
    end)

    # ProfileFilter still works — but now operates on 1K-10K samples, not 100K-1M
    filtered = ProfileFilter.filter(samples,
      function_length_threshold: state.function_length_threshold)

    Shipper.push(state.shipper_pid, %{
      trace_id: trace.trace_id,
      event_name: trace.event_name,
      event_identifier: trace.event_identifier,
      duration_us: total_duration,
      captured_at: Map.get(trace, :started_at),
      samples: filtered
    })
  end
end
```

**What's eliminated**: `Stack.finalize_stack`, `CollapsedStacks.convert`, and all recursive Block tree operations. The entire Block/Stack module pair becomes unused.

### 3.6 Adaptive Degradation

Instead of a single max_events cutoff, the TraceSession adapts its fidelity based on event volume:

| Event Count | Fidelity Level | Action |
|-------------|---------------|--------|
| 0 – 100K | **Full** | Capture all events (`:call`, `:return_to`, `:running`) |
| 100K – 300K | **Reduced** | Disable `:running` flag (halves event volume). Drop scheduling events. |
| 300K – 500K | **Minimal** | Disable `:return_to` flag. Only count function call frequencies, not durations. |
| > 500K | **Dropped** | Stop trace, discard all data. |

**Implementation**: At each fidelity transition, call `erlang:trace(pid, false, flags_to_remove)` to reduce the trace flags on the live process. This immediately reduces the event rate without stopping the trace entirely.

```elixir
defp maybe_degrade(state) do
  cond do
    state.event_count == 100_000 ->
      # Reduce: stop capturing scheduling events
      :erlang.trace(state.traced_pid, false, [:running])
      Logger.debug("[FlameOn] Trace degraded to reduced fidelity at 100K events")
      state

    state.event_count == 300_000 ->
      # Minimal: stop capturing returns (duration tracking disabled)
      :erlang.trace(state.traced_pid, false, [:return_to])
      Logger.debug("[FlameOn] Trace degraded to minimal fidelity at 300K events")
      state

    state.event_count >= 500_000 ->
      # Drop
      discard_trace(state)

    true ->
      state
  end
end
```

### 3.7 Cross-Process Call Handling (Adapted)

The seq_trace-based cross-process call tracking remains conceptually the same. When a cross-process GenServer.call is detected:

1. The `:seq_trace receive` message records the pending call
2. The `:seq_trace send` reply message completes the call
3. The completed call is injected into the stacks map as a `CALL <process> <message>` pseudo-frame appended to the current stack path at the time the call was made

The `pending_calls` and `completed_calls` maps in state are bounded by the number of concurrent cross-process calls (typically <100). No change needed.

### 3.8 Memory Analysis

| Component | Current Architecture | Phase 3 Architecture |
|-----------|---------------------|---------------------|
| Block tree | O(N) structs, N = events (100K-1M) | **Eliminated** |
| Call stack | Implicit in Block nesting | O(D) MFA tuples, D = max depth (~50) |
| Stacks map | N/A (built after trace) | O(P) entries, P = unique paths (1K-50K, configurable cap) |
| CollapsedStacks conversion | O(N × D²) intermediate allocations | **Eliminated** (stacks map IS collapsed stacks) |
| ProfileFilter | O(N × S²) string allocations | O(P × S) where P << N |
| Per-trace peak memory | **50-500 MB** | **1-10 MB** |

### 3.9 What's Lost

The streaming collapsed stacks approach trades some information for bounded memory:

1. **Exact call tree structure**: The Block tree preserves parent-child nesting. The stacks map preserves only leaf-to-root paths. You can still reconstruct the flame graph (that's what collapsed stacks are), but you lose the ability to compute exact self-time for intermediate nodes (self-time = own duration - children's duration). Instead, intermediate node times are the sum of all samples that pass through them (inclusive time), which is how flame graphs are typically displayed anyway.

2. **Exact per-invocation timing**: If function `Foo.bar/2` is called 10,000 times with different durations, the stacks map records the cumulative total, not the distribution. To get per-invocation stats, you'd need a separate sketch (e.g., reservoir sample of individual durations). This is a candidate for Phase 4 (Zig NIF could maintain a compact histogram per hot path).

3. **Temporal ordering**: The stacks map loses the order of function calls. You know `Foo.bar` took 45ms total but not when those 45ms occurred relative to other functions. Flame graphs don't need temporal ordering (they show cumulative time), so this is acceptable for the primary use case.

4. **Tail accuracy under eviction**: When the stacks map hits `max_stacks` and starts evicting, the smallest-duration paths are dropped. This means cold/rare code paths disappear first, which is the right behavior for profiling (you want to see the hot paths), but it means the flame graph is incomplete for cold paths.

---

## Phase 3 Module Changes Summary

### New Modules

None. Phase 3 is a rewrite of existing modules, not new ones.

### Modified Modules

| Module | Change |
|--------|--------|
| `TraceSession` | Complete rewrite of state and message handling. Block tree → streaming stacks map. Adaptive degradation. FinalizationGate integration. Mailbox depth check. |
| `ProfileFilter` | No code changes. Operates on the same `[%{stack_path, duration_us}]` format. But now receives 1K-10K samples instead of 100K-1M, so it's ~100x faster. |
| `PprofEncoder` | No changes. Same input format. |
| `Shipper` | No changes. |
| `Collector` | CircuitBreaker check, TraceDedupe check (from Phase 2). |

### Deprecated Modules (can be removed)

| Module | Reason |
|--------|--------|
| `Block` | Block struct no longer needed — call stack is a list of MFA tuples |
| `Stack` | Stack operations replaced by simple list push/pop on `call_stack` |
| `CollapsedStacks` | Conversion no longer needed — stacks map is already in collapsed format |

### Retained Unchanged

| Module | Reason |
|--------|--------|
| `Trace` | Still wraps erlang:trace — no change needed |
| `EventHandler` | Behavior interface unchanged |
| `EventHandler.Default` | Event definitions unchanged |
| `SeqTraceRouter` | Cross-process routing unchanged |
| `TraceSessionSupervisor` | DynamicSupervisor unchanged |
| `ErrorShipper` | Error pipeline unrelated to trace memory |
| `ErrorDedupe` | Error pipeline unrelated |
| `TraceContext` | Process dictionary trace ID unchanged |

---

## Configuration Summary (All Phases)

```elixir
config :flame_on_client,
  # Existing
  capture: true,
  sample_rate: 0.01,
  events: [...],
  function_length_threshold: 0.01,
  server_url: "...",
  api_key: "...",

  # Phase 1 (exists)
  max_events: 500_000,

  # Phase 2 (new)
  max_memory_bytes: :auto,             # 80% of system memory
  memory_check_interval_ms: 5_000,
  dedupe_enabled: true,
  dedupe_window_seconds: 60,
  max_concurrent_finalizations: 2,
  max_mailbox_depth: 50_000,

  # Phase 3 (new)
  max_stacks: 50_000,                  # max unique stack paths per trace
  adaptive_degradation: true,
  degradation_thresholds: [
    reduced: 100_000,                  # disable :running at this event count
    minimal: 300_000,                  # disable :return_to at this event count
    drop: 500_000                      # discard trace at this event count
  ]
```

---

## Testing Strategy

### Unit Tests

1. **Streaming stacks accumulation**: Verify that `:call`/`:return_to` sequences produce correct stack paths and cumulative durations.
2. **Eviction**: Verify that when `max_stacks` is reached, the smallest-duration path is evicted and replaced.
3. **Adaptive degradation**: Verify that trace flags are reduced at each threshold and that the trace is discarded at the final threshold.
4. **Mailbox depth check**: Verify that traces are stopped when mailbox exceeds the configured depth.

### Integration Tests

5. **CircuitBreaker**: Verify that traces are skipped when the breaker is tripped, and resume when it's cleared.
6. **TraceDedupe**: Verify that the same event_identifier is not traced twice within the window.
7. **FinalizationGate**: Verify that at most N finalizations run concurrently and excess traces are discarded.
8. **End-to-end**: Trace a real function, verify the shipped pprof data produces a valid flame graph.

### Stress Tests

9. **Memory bound verification**: Run a trace against a function that generates 1M+ function calls. Verify that peak process memory stays under 20MB (vs. current 500MB+).
10. **Concurrent trace stress**: Start 10 traces simultaneously. Verify that FinalizationGate limits concurrent processing and total memory stays bounded.
11. **Error cascade simulation**: Generate 100 failing requests in rapid succession with 100% sample rate. Verify that TraceDedupe limits traces to 1 per endpoint and CircuitBreaker trips if memory grows.

### Soak Test

12. **24-hour production simulation**: Run with realistic traffic patterns (varying request rates, occasional bursts, some slow requests) and verify memory stays within bounds over the full period. Track: peak RSS, ETS size, stacks map sizes, discard/degrade counts.

---

## Phase 4: Zig NIF (Future — Out of Scope)

Phase 4 moves post-processing (ProfileFilter + PprofEncoder) into a Zig NIF. The streaming stacks map from Phase 3 is serialized as a compact binary format and passed to the NIF for filtering, encoding, and optional additional analysis (per-path histograms, statistical summaries).

The Phase 3 architecture is designed to make this straightforward:
- The stacks map (`%{binary => integer}`) serializes trivially to a flat binary format
- The NIF receives a single binary, processes it in Zig-managed memory (outside BEAM heap), and returns a protobuf binary
- If the NIF crashes, only the current trace is lost — the BEAM process is unaffected (dirty NIF scheduler)

This document will be extended when Phase 4 implementation begins.
