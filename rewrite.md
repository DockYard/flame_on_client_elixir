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

---

## Phase 5: erl_tracer NIF with Ring Buffer

### 5.1 Problem Statement

FlameOn starts `erlang:trace` at the telemetry `:start` event and traces EVERY function call for the entire request duration. The 200ms threshold is only checked AFTER the trace ends, in `do_finalize_and_ship`. This means:

- **Every sampled request** (10% by default) pays full tracing cost
- **95%+ of traced requests** finish fast, and all trace data is discarded
- **The GenServer mailbox is unbounded** — `erlang:trace` sends messages faster than the TraceSession GenServer can process them
- **Production impact**: 70K+ message queues, 130MB+ binary references, repeated overflow warnings

The Phase 3 streaming architecture improved post-processing memory (O(P) stacks map instead of O(N) Block tree), but the fundamental problem remains: every trace event creates a BEAM message that lands in the TraceSession mailbox. The `{:tracer, self()}` option in `Trace.start_trace/2` means the traced process sends a message per event, and each message allocates on the BEAM heap, copies data, and enters an unbounded queue. The mailbox depth check (Phase 2.4) and adaptive degradation (Phase 3.6) are reactive — damage is already done by the time they fire.

### 5.2 Solution Overview

Replace the process-based tracer (`{:tracer, self()}`) with a Zig NIF implementing the `erl_tracer` behavior. The OTP `erl_tracer` module interface (introduced in OTP 19) allows a NIF module to receive trace events directly — bypassing the BEAM message queue entirely.

Key changes:

1. **Trace events write to a fixed-size ring buffer** (4MB default, configurable) in native memory via NIF callback — zero BEAM heap allocation per trace event
2. **Structural backpressure**: the `enabled/3` callback returns `:discard` when the buffer is >90% full, telling the VM to skip events before they are generated
3. **A drain timer** in TraceSession reads the buffer periodically and builds streaming collapsed stacks (reusing the Phase 3 `build_stack_path` + `add_to_stacks` pipeline)
4. **Full request tracing from the start** — no data loss for slow request root causes
5. **Total memory bounded by config**: `buffer_size x max_concurrent_traces`

### 5.3 Architecture

#### Ring Buffer (in Zig)

SPSC (single-producer, single-consumer) lock-free design using atomic read/write pointers. One buffer is allocated per traced process.

- **Fixed allocation**: 4MB default = ~125K events at 32 bytes each
- **Overflow policy**: overwrite oldest entries (the write pointer advances past the read pointer)
- **Entry format**: 32-byte packed struct

```
TraceEntry (32 bytes):
  event_type   : u8     — call, return_to, out, in
  arity        : u8     — function arity (0-255)
  _pad         : [6]u8  — alignment padding
  module_atom  : u64    — raw ERL_NIF_TERM value for module atom
  function_atom: u64    — raw ERL_NIF_TERM value for function atom
  timestamp_us : u64    — microsecond timestamp
```

Raw `ERL_NIF_TERM` values are stored for atoms because atoms are never garbage-collected in the BEAM — once created, an atom's term value is stable for the lifetime of the VM. This avoids the cost of converting atoms to strings in the hot path and defers string conversion to the drain phase.

**Sequence tracking**: The write pointer itself serves as the sequence number. No separate field is needed — the buffer position uniquely identifies each entry's order.

#### erl_tracer Callbacks (in Zig, as NIFs)

The OTP `erl_tracer` behavior requires two callbacks that the VM calls directly as NIFs. These are not Elixir functions — they are C-ABI NIF functions registered under the tracer module's name.

**`enabled/3` (~10ns)**:

Called by the VM before generating a trace event. This is the backpressure point.

```
enabled(TraceTag, TracerState, Tracee) -> trace | discard | remove

Implementation:
  1. Extract buffer resource from TracerState
  2. Check atomic "active" flag — if not active, return `remove`
     (tells VM to remove all trace flags from this process)
  3. Check buffer fill level — if >90% full, return `discard`
     (tells VM to skip this event but keep tracing)
  4. Otherwise return `trace`
     (tells VM to generate the event and call trace/5)
```

**`trace/5` (~200ns)**:

Called by the VM with the actual trace event data. This is the capture point.

```
trace(TraceTag, TracerState, Tracee, TraceTerm, Opts) -> ignored

Implementation:
  1. Extract event_type from TraceTag atom (:call, :return_to, :out, :in)
  2. Extract module, function, arity from TraceTerm
     (for :call/:return_to, TraceTerm is {Module, Function, Arity})
  3. Extract timestamp from Opts (the :timestamp option)
  4. Pack into 32-byte TraceEntry struct
  5. Atomic write to ring buffer:
     - Load current write_pos (atomic relaxed)
     - memcpy entry into buffer[write_pos % capacity]
     - Store write_pos + 1 (atomic release)
  6. Return (return value is ignored by the VM)
```

**`enabled/6`**: The 6-arity version is called for events that have extra data (e.g., `:send` and `:receive` with message content). Since FlameOn only traces `:call`, `:return_to`, and `:running`, this callback can simply delegate to `enabled/3`.

**`trace/6`**: Similarly, the 6-arity trace callback handles events with extra info. Delegate to `trace/5` or return immediately for unhandled event types.

#### Additional NIF Functions

These are regular NIF functions called from Elixir (not erl_tracer callbacks):

| Function | Purpose |
|----------|---------|
| `create_buffer(size_bytes)` | Allocate ring buffer as a NIF resource. Returns opaque reference. |
| `drain_buffer(buffer, max_count)` | Read up to N entries from the buffer. Advances the read pointer. Returns an Elixir list of `{event_type, module, function, arity, timestamp_us}` tuples. Atom terms are converted back to Elixir atoms here. |
| `buffer_stats(buffer)` | Returns `{write_pos, read_pos, capacity, overflow_count}` for monitoring. |
| `set_active(buffer, boolean)` | Set the atomic active flag. When false, `enabled/3` returns `:remove`. |
| `destroy_buffer(buffer)` | Explicit deallocation. Also happens automatically via NIF resource destructor when the Elixir reference is GC'd. |

#### TraceSession Changes

The TraceSession GenServer is modified to use the NIF tracer when available, falling back to the current message-based approach when the NIF is not loaded.

**`init/1` — NIF path**:

```elixir
case FlameOn.Client.TracerModule.available?() do
  true ->
    # Create ring buffer in native memory
    {:ok, buffer} = TracerModule.create_buffer(config.trace_buffer_size)

    # Start trace with NIF tracer module instead of self()
    :erlang.trace(traced_pid, true, [
      :call, :return_to, :running, :arity, :timestamp,
      {:tracer, FlameOn.Client.TracerModule, buffer}
    ])
    :erlang.trace_pattern({:_, :_, :_}, true, [:local])
    :erlang.trace_pattern(:on_load, true, [:local])

    # Start periodic drain timer
    Process.send_after(self(), :drain, config.drain_interval_ms)

    {:ok, %{state | buffer: buffer, tracer_mode: :nif}}

  false ->
    # Fall back to current GenServer-based approach
    Trace.start_trace(traced_pid, self())
    {:ok, %{state | tracer_mode: :genserver}}
end
```

**Remove ALL `handle_info({:trace_ts, ...})` handlers** — when in NIF mode, no trace messages arrive in the mailbox. The existing handlers remain for the GenServer fallback path.

**Add `handle_info(:drain, state)`** — periodic drain:

```elixir
def handle_info(:drain, %{tracer_mode: :nif} = state) do
  # Read a batch of events from the ring buffer
  events = TracerModule.drain_buffer(state.buffer, state.drain_batch_size)

  # Process through the same streaming collapsed stacks pipeline
  state = Enum.reduce(events, state, &process_nif_event/2)

  # Schedule next drain
  Process.send_after(self(), :drain, state.drain_interval_ms)
  {:noreply, state}
end
```

**`process_nif_event/2`** — converts NIF event tuples into the same state updates that the current `handle_info` clauses perform:

```elixir
defp process_nif_event({:call, module, function, arity, timestamp_us}, state) do
  mfa = {module, function, arity}
  %{state |
    call_stack: [mfa | state.call_stack],
    current_entry_time: timestamp_us,
    event_count: state.event_count + 1
  }
end

defp process_nif_event({:return_to, module, function, arity, timestamp_us}, state) do
  mfa = {module, function, arity}
  duration = timestamp_us - state.current_entry_time

  {stacks, stack_count} =
    if duration > 0 and state.call_stack != [] do
      path = build_stack_path(state.call_stack)
      add_to_stacks(state.stacks, state.stack_count, state.max_stacks, path, duration)
    else
      {state.stacks, state.stack_count}
    end

  call_stack = pop_stack_to(state.call_stack, mfa)

  %{state |
    call_stack: call_stack,
    stacks: stacks,
    stack_count: stack_count,
    current_entry_time: timestamp_us,
    event_count: state.event_count + 1
  }
end

# :out and :in handled similarly, updating scheduled_out_at / sleep stacks
```

**On trace end (`:DOWN` or `:stop`)**: perform a final drain to capture any remaining events in the buffer, then `finalize_and_ship` as before. The stacks map is already in collapsed format — no change to the shipping path.

#### Collector Changes

Minimal changes to the Collector:

- Pass `trace_buffer_size`, `drain_interval_ms`, and `drain_batch_size` through to TraceSession opts
- No change to when traces start — still at telemetry `:start` event after sampling
- The threshold check remains in `do_finalize_and_ship` (ship only if duration >= threshold)
- The cost of tracing a fast request is now ~N x 200ns of NIF writes + 4MB buffer allocation, not ~N x 2-5us of message sends + unbounded mailbox growth

#### Fallback Behavior

When the NIF is unavailable (compilation failure, unsupported platform, load error), the system falls back to the current GenServer-based approach with all Phase 1-3 protections active:

- TraceSession uses `{:tracer, self()}` and processes `{:trace_ts, ...}` messages
- Mailbox depth checks, adaptive degradation, max_events limits all apply
- The `tracer_mode` field in state controls which code path is active
- A single `Logger.info` at startup indicates which mode is in use

### 5.4 File Changes

#### In `flame_on_processor` (Zig NIF repository)

| File | Change |
|------|--------|
| `src/ring_buffer.zig` | **New** — standalone ring buffer data structure with SPSC atomics |
| `src/tracer_nif.zig` | **New** — erl_tracer callback implementations + NIF resource management |
| `build.zig` | **Modified** — include tracer NIF exports in the same shared library alongside the existing processor NIF |
| `.github/workflows/release.yml` | **Modified** — rebuild with tracer NIF; same artifact, same release |

The tracer NIF and processor NIF share a single `.so`/`.dylib` file. This avoids loading two separate shared libraries and simplifies distribution. The `build.zig` already builds `libflame_on_processor_nif`; it gains additional exported symbols for the tracer callbacks.

#### In `flame_on_client_elixir` (this repository)

| File | Change |
|------|--------|
| `lib/flame_on/client/tracer_module.ex` | **New** — Elixir module that loads the NIF and exposes `create_buffer/1`, `drain_buffer/2`, `buffer_stats/1`, `set_active/2`, `destroy_buffer/1`, and `available?/0`. Follows the same `@on_load` + `ensure_precompiled` pattern as `NativeProcessor`. |
| `lib/flame_on/client/trace_session.ex` | **Modified** — add `tracer_mode` to state, NIF init path, `:drain` handler, `process_nif_event/2`, final drain on stop. Existing `handle_info({:trace_ts, ...})` clauses retained for GenServer fallback. |
| `lib/flame_on/client/collector.ex` | **Modified** — pass NIF-related config through to TraceSession opts |
| `lib/flame_on/client/capture/trace.ex` | **Modified** — add `start_trace/3` clause that accepts `{:tracer, module, state}` tuple for NIF mode |

### 5.5 Configuration

```elixir
config :flame_on_client,
  # Ring buffer size per trace (bytes). Determines max events before overwrite.
  # 4MB = ~125K events at 32 bytes each.
  trace_buffer_size: 4 * 1024 * 1024,

  # How often the drain timer fires (milliseconds).
  # Lower = more responsive stacks map updates, higher = less overhead.
  drain_interval_ms: 1,

  # Max events read per drain cycle.
  # Bounds the time spent in a single drain to avoid blocking the GenServer.
  drain_batch_size: 10_000,

  # Buffer fill fraction at which enabled/3 returns :discard.
  # Events are skipped (not lost — the trace continues) until the drain
  # catches up and frees space.
  backpressure_threshold: 0.9
```

### 5.6 Memory Budget

Per trace: one ring buffer of `trace_buffer_size` bytes (4MB default), allocated in native memory (outside BEAM heap). The buffer is freed when the TraceSession terminates (via NIF resource destructor).

Max concurrent traces is controlled by `sample_rate` + `CircuitBreaker` + `MemoryWatcher` (Phase 2). The ring buffers add a predictable, bounded cost:

| Scenario | Active Traces | Buffer Memory |
|----------|--------------|---------------|
| 1% sample rate, 100 concurrent requests | ~1 | 4MB |
| 10% sample rate, 100 concurrent requests | ~10 | 40MB |
| 10% sample rate, 1000 concurrent requests | ~100 | 400MB |
| 100% sample rate, 1000 concurrent requests | ~1000 | 4GB |

The last scenario is pathological and would be caught by `MemoryWatcher` tripping the `CircuitBreaker` well before reaching 1000 active traces. In practice, 10-50 concurrent traces is the upper bound for production use.

### 5.7 Performance Comparison

| Metric | Current (GenServer) | NIF Tracer |
|--------|-------------------|------------|
| Per-event capture cost | ~2-5us (message copy to mailbox) | ~200ns (NIF write to ring buffer) |
| Max throughput | ~200K events/sec | ~2-5M events/sec |
| Traced process heap impact | Message allocation per event | Zero |
| Backpressure | Reactive (mailbox check every 1K events) | Proactive (`enabled/3` called by VM every event) |
| Overflow behavior | 70K+ queued messages, 130MB+ | Fixed buffer, oldest overwritten |
| Memory bound | Unbounded (mailbox grows with event count) | Fixed (4MB default, configurable) |
| Fast request cost (discarded trace) | 50K messages created + GC'd | 50K x 200ns NIF writes = 10ms + 4MB freed |
| TraceSession mailbox depth | Grows with event rate | Zero trace messages (only `:drain` timer) |

### 5.8 Implementation Order

1. **`ring_buffer.zig`** — standalone data structure with comprehensive tests: SPSC correctness, overflow/wrap-around, atomic ordering, concurrent read/write
2. **`tracer_nif.zig`** — erl_tracer callbacks using ring_buffer, NIF resource type for buffer lifecycle, `create_buffer`/`drain_buffer`/`buffer_stats`/`set_active`/`destroy_buffer` exports
3. **Update `build.zig`** — include tracer exports in the shared library, ensure both processor and tracer symbols are exported
4. **`tracer_module.ex`** — Elixir NIF wrapper following the `NativeProcessor` pattern (`@on_load`, `ensure_precompiled`, fallback stubs)
5. **Modify `trace_session.ex`** — add NIF init path, drain-based processing, `tracer_mode` branching, final drain on stop
6. **Modify `collector.ex`** — pass NIF config through to TraceSession
7. **Modify `capture/trace.ex`** — add NIF-aware `start_trace/3`
8. **Tests** — ring buffer overflow, backpressure (`enabled/3` returns `:discard`), drain correctness, NIF-to-stacks-map pipeline, GenServer fallback, concurrent traces with independent buffers
9. **Update GitHub Action** — rebuild release artifact with tracer NIF symbols
10. **Tag release** — new version of `flame_on_processor`

### 5.9 Risks and Mitigations

1. **NIF bugs crash the VM.** Zig's safety features (bounds checking, null safety, no undefined behavior in safe mode) reduce this risk significantly. The ring buffer is a simple data structure with a small API surface. Extensive testing at the Zig level (step 1) catches issues before BEAM integration. The `destroy_buffer` NIF resource destructor ensures cleanup even on abnormal TraceSession termination.

2. **Atom term storage.** Raw `ERL_NIF_TERM` values for atoms are stable for VM lifetime since atoms are never GC'd, but this is not formally guaranteed across hot code upgrades. In practice, atom term values do not change during hot upgrades — only module code is swapped. This is an acceptable risk for a profiling tool. If a hot upgrade does invalidate atom terms, the worst case is garbled function names in one flame graph, not a crash.

3. **SPSC assumption.** One buffer per traced process. The VM calls `trace/5` from the scheduler thread running the traced process (single producer). The TraceSession GenServer drains the buffer (single consumer). Multiple concurrent traces each get their own buffer — no sharing, no contention.

4. **OTP compatibility.** The `erl_tracer` behavior was introduced in OTP 19 (2016). All supported OTP versions (25+) include it. The `:tracer` option in `erlang:trace/3` accepts `{Module, State}` where `Module` implements the behavior as NIFs.

5. **Drain latency.** With a 1ms drain interval and 10K batch size, there is up to 1ms of latency between an event occurring and it being processed into the stacks map. This is irrelevant for profiling — flame graphs are post-hoc analysis, not real-time. If the traced process generates events faster than the drain can process them, the ring buffer absorbs the burst (up to 125K events at default size), and `enabled/3` applies backpressure beyond that.

6. **Cross-process tracing.** The `seq_trace` mechanism for cross-process GenServer.call tracking still uses BEAM messages (routed through `SeqTraceRouter`). These are low-volume (one message per cross-process call, not per function call) and remain unchanged. Only the high-volume `:call`/`:return_to`/`:running` events move to the NIF path.
