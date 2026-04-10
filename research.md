# FlameOn Client: Production Memory Safety Research

## The Problem

On April 10, 2026, the DockYard production application (a content site running on Fly.io) experienced memory growth from 3.1GB to 7.8GB in under 6 minutes, triggering an OOM kill. Investigation revealed three `FlameOn.Client.TraceSession` processes holding a combined **1,987 MB of binary data**, stuck in post-processing functions that could not keep up with the volume of trace data.

The root cause was a cascade: a deployment bug caused 500 errors on every blog post URL (~600+ pages). FlameOn sampled 10% of these requests. Each sampled request exceeded the 200ms duration threshold and generated a full execution trace. The trace post-processing algorithms have quadratic time and space complexity, so each trace consumed hundreds of megabytes during finalization. Three traces processing simultaneously exhausted available memory.

This document analyzes FlameOn's architecture, compares it against every major production tracing tool on the BEAM, and identifies what must change for FlameOn to be safe in production.

---

## How FlameOn Works Today

### Trace Lifecycle

1. **Trigger**: A telemetry event fires (e.g., `[:phoenix, :router_dispatch, :start]`). The Collector checks the sample rate (default 10%) and duration threshold (default 200ms for HTTP requests).

2. **Capture**: If sampled, a `TraceSession` GenServer is spawned via DynamicSupervisor. It calls `erlang:trace(pid, true, [:call, :return_to, :running, :arity, :timestamp])` on the request process. Every function call in that process generates a message to the TraceSession's mailbox.

3. **Accumulation**: Each trace message (`:call`, `:return_to`, `:in`, `:out`) creates a `Block` struct that is pushed onto a stack in the GenServer state. For a 200ms request, this can be 50,000–500,000 function calls. For a slow request (1+ seconds), it can exceed 1,000,000.

4. **Termination**: The trace ends when either the telemetry `:stop` event fires (normal case) or the traced process dies (fallback). The erlang trace is stopped and `finalize_and_ship` runs.

5. **Post-processing**: `finalize_and_ship` converts the Block tree to collapsed stacks via `CollapsedStacks.walk/2`, then filters via `ProfileFilter.filter/2`, then encodes to pprof protobuf and ships to the FlameOn server.

### Where Memory Explodes

The post-processing step is where memory becomes unmanageable. Two functions have quadratic behavior:

#### CollapsedStacks.walk/2

```elixir
defp walk(%Block{children: children, function: function}, ancestors) do
  current_path = ancestors ++ [function]  # O(N) copy every recursive call
  child_entries = Enum.flat_map(children, fn child ->
    walk(child, current_path)
  end)
  ...
end
```

`ancestors ++ [function]` copies the entire ancestor list on every recursive call. For a trace with depth 20 and 100K leaf blocks, this creates ~2M intermediate list allocations totaling hundreds of megabytes.

#### ProfileFilter.build_inclusive_times/1

```elixir
defp path_prefixes(path) do
  parts = String.split(path, ";")
  parts |> Enum.scan(fn part, acc -> acc <> ";" <> part end)
end
```

For each sample, `Enum.scan` with string concatenation creates every prefix of the stack path as a new binary string. With 100K samples at average depth 8, this generates 700K new strings totaling ~1.5GB. The `build_inclusive_times` reducer then stores all these strings as map keys, keeping them alive for the duration of the reduce.

### Missing Safety Mechanisms

Before our fixes, FlameOn had:

- **No max event count**: A trace could accumulate unlimited Block structs
- **No finalization timeout**: Post-processing could run indefinitely
- **No memory limit per trace**: A single trace could consume all available heap
- **No backpressure**: New traces started regardless of how many were already processing
- **No circuit breaker**: No mechanism to disable tracing under memory pressure

---

## Fixes Applied (April 2026)

1. **CollapsedStacks.walk/2**: Replaced `ancestors ++ [function]` with a reversed accumulator (`[function | ancestors_reversed]`), reducing list operations from O(N) per call to O(1).

2. **ProfileFilter.path_prefixes/1**: Replaced eager string concatenation with `:binary.matches/2` + `binary_part/3`, creating sub-binary references instead of new string allocations.

3. **max_events**: Added a configurable limit (default 500K) to TraceSession. Traces exceeding this are discarded immediately with a warning log.

4. **Finalization timeout**: Wrapped post-processing in `Task.async` with a 10-second timeout. Traces that take too long to process are killed and discarded.

### Tradeoffs of These Fixes

- **max_events at 500K**: Legitimate complex traces from heavy Oban jobs or data processing may be silently discarded. The threshold is an arbitrary guess without production data on typical trace sizes.
- **10-second timeout**: A large but legitimate trace on a slow machine may not finish processing in time. The timeout is not adaptive to system load.
- **binary_part sub-references**: Sub-binaries hold a reference to the original large binary, preventing GC of the parent. In patterns where many small sub-binaries are kept alive, the original binary stays in memory. The old approach of creating independent strings allowed the original to be freed.
- **Overall**: We traded observability for safety using blunt instruments. Adaptive degradation (reduce trace detail instead of dropping entirely) would be better long-term.

---

## Comparative Analysis: Production Tracing on the BEAM

### The Fundamental Tension

Every tool that provides **function-level** flame graph data uses `erlang:trace` and is inherently risky in production. `erlang:trace` sends a message per function call to the tracer process. BEAM mailboxes are unbounded — they grow until OOM. A function called millions of times per second fills a mailbox in seconds.

Every tool that is **production-safe** either uses `erlang:trace` with hard mandatory caps (recon_trace), or avoids `erlang:trace` entirely in favor of telemetry events, NIFs, or process_info sampling. The tradeoff: production-safe tools give request/operation-level visibility ("this request took 200ms") but not function-level visibility ("line 47 of this module took 180ms").

### Tool-by-Tool Analysis

#### recon_trace (ferd/recon)

The gold standard for production-safe BEAM tracing, designed by Fred Hebert (author of "Erlang in Anger").

- **Capture**: `erlang:trace/3` with match specifications
- **Memory management**: Three-tier architecture (Shell → Tracer → Formatter). Tracer does minimal work.
- **Safety**: **Mandatory** rate limiting on every call — either absolute count (`10`) or rate (`{10, 100}` = 10 msgs per 100ms). You literally cannot call it without specifying a bound. Tracing auto-stops when the limit is hit. Bans wildcard module matches. Linked to calling shell — disconnection kills tracing. Resets trace patterns on each call.
- **Long-lived processes**: Safe — rate limits apply regardless of process lifetime.
- **Output**: Formatted text to shell. No flame graphs.
- **Complexity**: O(n) where n = matched calls, hard-capped by configured limit.

**Key lesson for FlameOn**: Limits must be mandatory, not optional. recon_trace proves that `erlang:trace` can be production-safe if you enforce bounds at the API level.

#### observer_cli

- **Capture**: `erlang:process_info/2`, `erlang:statistics/1`, `erlang:memory/0`. Does NOT use `erlang:trace`.
- **Memory**: Read-only sampling with no state accumulation. Each refresh is independent.
- **Safety**: All APIs are read-only. Uses explicit timeouts. Pagination for large process lists.
- **Output**: Terminal UI with real-time process/memory/scheduler metrics.

**Key lesson**: Sampling-based monitoring (periodic `process_info` snapshots) is zero-risk. FlameOn could offer a "light mode" that samples stack traces at intervals instead of tracing every call.

#### eflame / eflame2

- **Capture**: `erlang:trace/3`. eflame2 (Fritchie fork) uses time-sampling (stack trace every ~100ms).
- **Memory**: None. eflame2 documentation states it "can easily create 1 GByte or more of trace data."
- **Safety**: eflame: "Tracing can slow down a Riak system by 2-3 orders of magnitude." eflame2's sampling is safer but requires a custom-patched Erlang VM.
- **Output**: Collapsed stacks → SVG flame graph via Brendan Gregg's `flamegraph.pl`.

**Key lesson**: eflame2's time-sampling approach (100ms intervals) produces flame graphs with dramatically less data than full call tracing. Custom VM requirement makes it impractical, but the concept is sound.

#### eflambe

- **Capture**: Uses meck to mock target modules with passthrough, wrapping in `erlang:trace`.
- **Memory**: No explicit bounding. Trace messages accumulate in the tracer mailbox.
- **Safety**: Supports `eflambe:capture(M, F, Arity, NumCalls)` to limit invocations, but within each invocation all internal calls are fully traced. The meck approach affects all callers system-wide.
- **Output**: Collapsed stacks or SVG. Compatible with Speedscope.

**Key lesson**: Limiting at the invocation level (N calls to this function) is a useful complement to event-level limits. FlameOn could adopt this: "trace at most 3 requests to /blog, then stop."

#### OpenTelemetry BEAM SDK

- **Capture**: Does NOT use `erlang:trace`. Manual/automatic instrumentation via telemetry events. Spans created through the Tracer API.
- **Memory**: ETS-based double buffering. Two ETS tables rotate — one accepts spans while the other exports. Tables created with `write_concurrency`.
- **Backpressure**: When `max_queue_size` (default 2048) is reached, the batch processor **disables span insertion** via `persistent_term` flag. New spans return `:dropped`. Re-enabled after export.
- **Long-lived processes**: Span sweeper runs on configurable interval (default 600s), checks for spans older than `span_ttl` (default 1800s). Can drop or force-end stale spans.
- **Post-processing**: Batch processor spawns a linked runner, transfers ETS table ownership via `ets:give_away/3`, runner exports, then deletes the table. Fully async, isolated from collection.
- **Safety**: Span limits: max 128 attributes, 128 events, 128 links per span. Samplers: `always_on`, `always_off`, `traceidratio`, `parentbased_*`. Export timeout: 30s.
- **Complexity**: Span insertion O(1). Export O(n). Sweeper O(n) on interval.

**Key lesson**: The `persistent_term` disable flag is elegant — zero-overhead killswitch. The double-buffered ETS design with table rotation prevents export from blocking collection. The span sweeper handles the "what if a span is never closed" problem that FlameOn also faces (traces that never finalize).

### Commercial Tools

#### AppSignal

- **Capture**: Rust NIF + separate forked agent process. Does NOT use `erlang:trace`. NIF returns immediately, hands off to Rust worker thread via C FFI. Worker sends protobuf over Unix domain socket to a forked process.
- **Memory**: Zero GC pressure on BEAM — all buffering in the Rust agent (outside BEAM heap).
- **Safety**: "In the very unlikely event that something in the extension panics, the extension disables itself without bringing down the host process." Same Rust core processes "1 billion requests per day" across production customers.
- **Output**: AppSignal dashboard — transaction timelines, error tracking, host metrics.

**Key lesson**: Out-of-process architecture is the safest possible design. Even a catastrophic bug in the monitoring code cannot OOM the BEAM. FlameOn's post-processing (CollapsedStacks, ProfileFilter) could be moved to a NIF or Port to achieve the same isolation.

#### Sentry for Elixir

- **Capture**: Telemetry events + OpenTelemetry spans. Does NOT use `erlang:trace`.
- **Memory**: Two paths:
  - **SenderPool** (older): GenServer.cast to a pool of 8+ senders. The GenServer mailbox IS the queue. **No explicit bounded buffer.** Counters track queued items but do not enforce limits.
  - **TelemetryProcessor** (newer): Bounded `:queue` per category (100 errors, 1000 transactions). Drop-oldest when full. Transport queue capped at 1000 items.
- **Backpressure**: SenderPool: **none** (unbounded mailbox growth risk). TelemetryProcessor: bounded queues with drop-oldest. Server-driven rate limiting via `X-Sentry-Rate-Limits` headers → ETS lookup before each send.
- **Retry**: 4 retries at [1s, 2s, 4s, 8s]. `Process.sleep` blocks the sender GenServer during retry. No jitter.
- **Deduplication**: ETS-based dedup with 30-second TTL window. Identical exceptions within the window are dropped.
- **OTel integration**: Custom span processor stores spans in ETS with 30-minute TTL. Cleanup every 5 minutes for orphaned spans.
- **Per-request overhead**: ~1-5 KB in ETS while transaction is in-flight. Freed after send.

**Key lesson**: Sentry's SenderPool has the same unbounded-mailbox risk as FlameOn, just at much lower data volume (~10KB per error vs ~1GB per trace). The newer TelemetryProcessor with bounded queues and drop-oldest is the safer path. The dedup mechanism (ETS + TTL) is relevant for FlameOn: don't trace the same failing endpoint repeatedly.

#### Datadog: Spandex (Community Library)

- **Capture**: Telemetry events, manual spans. Does NOT use `erlang:trace`.
- **Span storage**: Process dictionary via `Spandex.Strategy.Pdict`. Each process has its own isolated trace. No ETS, no GenServer for span storage. Spans are plain Elixir structs on the process heap, GC'd when the process exits.
- **Batching**: `SpandexDatadog.ApiServer` GenServer accumulates traces in `waiting_traces` list. Flushes when `batch_size` (default 10 traces) is reached. **No flush timer** — if traffic is low, traces sit in memory indefinitely.
- **Backpressure** (`sync_threshold`): An Agent holds a counter of concurrent async export tasks. When count < 20: exports are fire-and-forget (`Task.start`). When count >= 20: exports become **synchronous** (`Task.async` + `Task.await`) — the GenServer blocks, which propagates backpressure to callers. The application slows down instead of memory growing.
- **When dd-agent is down**: No retry logic. Failed exports are silently lost. The sync_threshold mechanism causes the app to slow if exports are timing out.
- **Limits**: No max span count per trace. No max batch size cap beyond `batch_size` triggering a flush. No payload size limit.
- **Context propagation**: Manual. Process dictionary is per-process, so spawning a Task loses trace context. Requires explicit `Tracer.current_context()` capture and `Tracer.continue_trace()` in the child.
- **Per-request overhead**: ~2-5 KB in the process dictionary for 5-10 spans.

**Key lesson**: Spandex's `sync_threshold` is the most elegant backpressure mechanism in the comparison. It degrades gracefully: under normal load, exports are fully async with zero impact. Under pressure, the system slows down proportionally. FlameOn could adopt this: when N traces are already being processed, new trace finalization blocks the TraceSession instead of spawning another concurrent processor.

#### Datadog: OpenTelemetry Path

Datadog does not have an official Elixir SDK. The recommended path is the standard OTel Erlang/Elixir SDK with OTLP export to the Datadog Agent (v7.32+, port 4317/4318).

This inherits all of OTel's production safety mechanisms (double-buffered ETS, persistent_term disable flag, span sweeper, max_queue_size). The tradeoff: some Datadog-specific features (sampling priority propagation, container ID detection) require the community `opentelemetry_datadog` exporter, which has limited maintenance.

Compared to Spandex, OTel stores spans in shared ETS (accessible from any process) instead of per-process dictionaries, which simplifies context propagation for async work but introduces ETS write contention under very high throughput (mitigated by `write_concurrency`).

---

## Summary Comparison Table

| Mechanism | FlameOn | recon_trace | OTel SDK | AppSignal | Sentry | Spandex |
|---|---|---|---|---|---|---|
| Capture method | `erlang:trace` (all calls) | `erlang:trace` (match specs) | Telemetry events | Rust NIF | Telemetry + OTel | Telemetry events |
| Events per request | 50K–1M+ | Hard-capped by user | 5–20 spans | 5–20 spans | 5–20 spans | 5–20 spans |
| Data per request | 50–500 MB (Block tree) | <1 KB (text) | 1–5 KB (ETS) | ~0 on BEAM | 1–5 KB (ETS) | 2–5 KB (pdict) |
| Max buffer | 500K events (our fix) | Mandatory limit | 2048 spans | Out-of-process | 1000 items (new path) | None (unbounded) |
| Backpressure | 10s timeout (our fix) | Auto-stop at limit | Disable via persistent_term | N/A (out of BEAM) | Drop-oldest (new path) | sync_threshold blocks caller |
| Retry on failure | None | N/A | None | Agent-side | 4x exponential | None |
| Orphan cleanup | None | Auto-stop on shell disconnect | Span sweeper (TTL) | N/A | Span sweeper (30min) | GC on process exit |
| Circuit breaker | None | Mandatory limits | persistent_term flag | NIF self-disables | Server-driven rate limits | sync_threshold |
| Output granularity | Function-level flame graph | Function call text | Request/operation spans | Request/operation spans | Request/operation spans | Request/operation spans |
| Production safe? | Partially (after fixes) | Yes (by design) | Yes | Yes (battle-tested) | Mostly (new path) | Yes |

---

## Recommendations for FlameOn

### Short-term (applied)

1. Fix quadratic algorithms in post-processing ✅
2. Add max_events limit ✅
3. Add finalization timeout ✅

### Medium-term

4. **Mandatory limits at the API level** (recon_trace pattern): Make it impossible to start a trace without specifying a bound. The current `max_events` default is good, but it should not be possible to set it to infinity.

5. **persistent_term disable flag** (OTel pattern): When system memory exceeds a threshold (e.g., 80% of available), flip a single `persistent_term` flag that makes all new trace decisions return `:skip`. Zero overhead when disabled — a single `persistent_term` read is nanoseconds.

6. **Deduplication** (Sentry pattern): Don't trace the same failing endpoint repeatedly. If `/blog/some-post` already generated a trace in the last 60 seconds, skip it. An ETS-based dedup with TTL window prevents the error cascade scenario that caused the original OOM.

7. **sync_threshold for finalization** (Spandex pattern): When N traces are already being post-processed, don't start processing another — either queue it with a bounded buffer (drop-oldest if full) or block the TraceSession until a processing slot opens.

8. **Adaptive degradation instead of hard drops**: When a trace exceeds 100K events, switch to reduced-fidelity mode: stop capturing `:running` (scheduling) events (which roughly halve event volume) and increase the `function_length_threshold` to filter more aggressively during finalization. Only discard at 500K+.

### Long-term

9. **Out-of-process post-processing** (AppSignal pattern): Move CollapsedStacks and ProfileFilter into a NIF or Port. The trace data is serialized and sent to an external process for conversion. Even catastrophic bugs in the conversion code cannot affect the BEAM heap.

10. **Time-based sampling mode** (eflame2 pattern): Instead of tracing every function call, periodically sample the process stack (e.g., every 1ms) via `Process.info(pid, :current_stacktrace)`. This produces statistical flame graphs with 1000x less data. Less precise than full call tracing, but production-safe by construction. Could be offered as a "light profiling" mode alongside the existing full trace mode.

---

## Architecture Spectrum: Most Dangerous to Safest

1. **Unbounded mailbox** (eflame, eflambe, FlameOn before fixes) — no protection at all
2. **Hard message count** (recon_trace, FlameOn after fixes) — stops after N events
3. **Rate limiting** (recon_trace) — N events per time window
4. **ETS with max size + disable flag** (OTel) — stops accepting when full, resumes after export
5. **Reservoir sampling** (New Relic) — fixed-size buffer, random eviction
6. **Sync backpressure** (Spandex) — slows the application instead of growing memory
7. **Out-of-process** (AppSignal) — all buffering outside BEAM heap entirely

FlameOn is currently at level 2. The goal is to reach level 5-6 (bounded buffers with graceful degradation) without sacrificing the function-level flame graph capability that is FlameOn's core value proposition.
