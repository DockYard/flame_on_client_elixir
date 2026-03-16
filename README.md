# FlameOn Client

Production profiling client for Elixir applications. Captures per-process call stacks from telemetry events and ships them to [FlameOn](https://flameon.ai) for flame graph visualization.

It can also report structured runtime errors to FlameOn over gRPC.

## How It Works

1. **Telemetry events** fire in your application (Phoenix requests, Oban jobs, LiveView events, etc.)
2. The **Collector** receives the event synchronously (via `GenServer.call`), rolls the dice against your sample rate, and spawns a **TraceSession** process (via `DynamicSupervisor`) that calls `:erlang.trace/3` on the calling process — the caller blocks until tracing is active, ensuring the complete call chain is captured
3. Trace messages (`:call`, `:return_to`, scheduling in/out) stream into the **TraceSession** (not the Collector), which builds a hierarchical call stack in real time. This keeps the Collector's mailbox clear so it stays responsive to new telemetry events under load.
4. When the traced process exits (or the corresponding `:stop` telemetry event fires), the TraceSession **finalizes** the stack into a block tree, then **collapses** it into root-to-leaf stack paths with durations, and terminates
5. **Threshold filtering** drops traces whose total duration is below the event's configured threshold — only slow traces get shipped
6. The **ProfileFilter** removes the children of any block whose inclusive duration is below the `function_length_threshold` (default 1%) — the block itself is kept as a leaf with its full duration, but its sub-call detail is discarded to reduce noise and payload size
7. The **Shipper** batches filtered stacks, encodes each trace as a [pprof](https://github.com/google/pprof/blob/main/proto/profile.proto) `Profile`, and ships them to FlameOn over gRPC

The only synchronous overhead on the traced process is the initial trace setup (step 2). After that, trace messages flow asynchronously to a dedicated per-trace process — no application code runs in the hot path, and the Collector never handles trace messages directly.

## Installation

Add `:flame_on_client` to your dependencies:

```elixir
def deps do
  [
    {:flame_on_client, "~> 0.1.0"}
  ]
end
```

## Configuration

```elixir
# config/runtime.exs
if config_env() == :prod do
  config :flame_on_client,
    capture: true,
    capture_errors: true,
    api_key: System.get_env("FLAMEON_API_KEY"),
    service: "my_app",
    environment: "prod",
    release: System.get_env("RELEASE_NAME") || System.get_env("GIT_SHA") || "unknown",
    sample_rate: 0.01,
    function_length_threshold: 0.01
end
```

### All Options

| Key | Default | Description |
|-----|---------|-------------|
| `capture` | `false` | Must be `true` to enable tracing and shipping. When `false`, the client starts an empty supervisor and does nothing. |
| `capture_errors` | `false` | Must be `true` to enable runtime error batching and shipping. |
| `api_key` | `nil` | API key from your FlameOn account, sent as gRPC metadata |
| `before_send` | `nil` | Optional `fn event -> event | nil end` hook to mutate or drop outgoing error events |
| `logger_fallback` | `false` | Attach a logger handler that turns error-level logger events into FlameOn error events |
| `service` | `"unknown"` | Service name attached to shipped error events |
| `environment` | `"production"` | Deployment environment attached to shipped error events |
| `release` | `"unknown"` | Release/version attached to shipped error events |
| `sample_rate` | `0.01` | Fraction of events to trace (0.0 to 1.0) |
| `function_length_threshold` | `0.01` | Remove children of blocks below this fraction of total request time (min: `0.005`) |
| `error_flush_interval_ms` | `5000` | How often to flush queued error events |
| `error_dedupe_window_ms` | `5000` | Time window for suppressing duplicate error events from the same process |
| `max_error_batch_size` | `50` | Flush immediately when this many error events are buffered |
| `max_error_buffer_size` | `500` | Maximum queued error events before dropping oldest entries |
| `max_string_length` | `2000` | Maximum stored string length for error payload fields |
| `max_breadcrumbs` | `50` | Maximum breadcrumbs kept on a single error event |
| `events` | *(see below)* | List of telemetry events to listen to |
| `event_handler` | `FlameOn.Client.EventHandler.Default` | Module that decides which events to capture |

## Runtime Error Reporting

Phase 1 supports manual runtime error reporting and ships structured `ErrorEvent` payloads to FlameOn's `FlameOnErrorIngest.IngestErrors` gRPC API.

```elixir
try do
  Payments.charge!(invoice)
rescue
  exception ->
    FlameOn.Client.Errors.capture_exception(exception,
      stacktrace: __STACKTRACE__,
      request: %{
        method: "POST",
        url: "https://example.com/invoices/123/charge",
        route: "POST /invoices/:id/charge"
      },
      tags: %{area: "billing"},
      contexts: %{invoice_id: "123"}
    )

    reraise exception, __STACKTRACE__
end
```

You can also report handled application errors without an exception:

```elixir
FlameOn.Client.Errors.capture_message("payment gateway timeout",
  severity: "warning",
  fingerprint: ["billing", "gateway-timeout"],
  handled: true
)
```

`capture_exception/2` defaults to `handled: true` because it is a manual API. Pass `handled: false` when you are reporting an unhandled failure boundary.

When an error is captured inside an actively traced process, the client automatically attaches the current FlameOn `trace_id` so the server can link the error event back to the matching trace.

### Phoenix Plug Integration

For automatic request exception capture, wrap the part of your endpoint or pipeline you want to observe with `FlameOn.Client.PhoenixPlug`:

```elixir
defmodule MyAppWeb.FlameOnErrorPlug do
  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    FlameOn.Client.PhoenixPlug.call(conn, fn conn ->
      MyAppWeb.Router.call(conn, MyAppWeb.Router.init([]))
    end)
  end
end
```

The plug captures the raised exception, attaches request/user context when available, reports it as `handled: false`, and then reraises so your normal Phoenix error flow is unchanged.

### Redaction And `before_send`

Error events automatically redact common secret fields like `authorization`, `cookie`, `password`, `secret`, and `token`. You can add more fields per capture call with `redact_fields`:

```elixir
FlameOn.Client.Errors.capture_message("login failed",
  contexts: %{password: "secret", safe: "ok"},
  redact_fields: [:password]
)
```

You can also mutate or drop events globally:

```elixir
config :flame_on_client,
  before_send: fn event ->
    cond do
      event.message == "ignore me" ->
        nil

      true ->
        %{event | severity: "warning"}
    end
  end
```

### Per-Process Context

You can attach context to the current process and it will be included automatically in later error captures from that process:

```elixir
FlameOn.Client.Errors.set_user(%{id: current_user.id, email: current_user.email})
FlameOn.Client.Errors.set_tags(%{area: "billing", region: "us-east-1"})
FlameOn.Client.Errors.set_context(:tenant, %{id: tenant.id})
FlameOn.Client.Errors.add_breadcrumb(%{category: "request", message: "checkout started"})

FlameOn.Client.Errors.capture_message("payment failed")

FlameOn.Client.Errors.clear_context()
```

Explicit options passed to `capture_exception/2` or `capture_message/2` override stored user data and merge with stored tags, contexts, and breadcrumbs.

### Oban Integration

For automatic job failure reporting, call `FlameOn.Client.ObanReporter.capture_exception/3` from your Oban failure boundary or worker wrapper:

```elixir
try do
  perform_job(job)
rescue
  exception ->
    FlameOn.Client.ObanReporter.capture_exception(job, exception, __STACKTRACE__)
    reraise exception, __STACKTRACE__
end
```

The reporter marks the event as `handled: false`, uses `route: "oban.job"`, and attaches common job metadata such as `worker`, `queue`, `attempt`, `max_attempts`, and `args`.

### LiveView Integration

For LiveView event failures, report the exception from your event boundary:

```elixir
try do
  handle_event_logic(socket, event, params)
rescue
  exception ->
    FlameOn.Client.LiveViewReporter.capture_exception(socket, event, exception, __STACKTRACE__)
    reraise exception, __STACKTRACE__
end
```

This tags the event as `live_view.event` and includes the view name plus current user when available.

### Logger Fallback

If you want a broad last-resort fallback for runtime failures that hit Logger, enable:

```elixir
config :flame_on_client,
  capture_errors: true,
  logger_fallback: true
```

This converts error-and-higher logger events into FlameOn error events with `route: "logger.error"`. Internal FlameOn logs are ignored to avoid loops.

### Duplicate Suppression

The client suppresses duplicate error events within a short per-process window so the same failure path does not flood FlameOn repeatedly:

```elixir
config :flame_on_client,
  error_dedupe_window_ms: 5_000
```

The dedupe key uses the event message, route, severity, handled flag, trace id, and top exception frame. After the window expires, the same error can be sent again.

### Events and Threshold Filtering

Each event can be a bare list (uses the handler's default threshold) or a `{event, opts}` tuple with an explicit `threshold_ms`:

```elixir
config :flame_on_client,
  events: [
    {[:phoenix, :router_dispatch, :start], threshold_ms: 500},
    [:oban, :job, :start],
    {[:phoenix, :live_view, :handle_event, :start], threshold_ms: 200},
    {[:phoenix, :live_component, :handle_event, :start], threshold_ms: 200},
    {[:absinthe, :execute, :operation, :start], threshold_ms: 1_000}
  ]
```

Traces whose total duration is below the threshold are dropped — only slow traces get shipped. When no `threshold_ms` is provided, the event handler's `default_threshold_ms/1` callback is used.

#### Default Thresholds

The built-in `Default` handler provides these defaults:

| Event | Default threshold |
|-------|-------------------|
| Phoenix request | 500 ms |
| Oban job | 30,000 ms |
| LiveView event | 200 ms |
| LiveComponent event | 200 ms |
| Absinthe operation | 1,000 ms |
| *(any other event)* | 100 ms |

You can trim this list to only the events your app produces, or add custom telemetry events with a custom event handler.

## Default Event Handlers

The built-in `FlameOn.Client.EventHandler.Default` handles:

| Event | `event_name` | `event_identifier` |
|-------|-------------|-------------------|
| Phoenix request | `"phoenix.request"` | `"GET /users/:id"` |
| Oban job | `"oban.job"` | `"MyApp.Workers.SendEmail"` |
| LiveView event | `"live_view.event"` | `"MyApp.UserLive.save"` |
| LiveComponent event | `"live_component.event"` | `"MyApp.SearchComponent.filter"` |
| Absinthe operation | `"graphql.operation"` | `"GetUser"` or `"anonymous"` |

Unrecognized events are skipped.

## Custom Event Handlers

To handle additional telemetry events or override default behavior, create a module using the `FlameOn.Client.EventHandler` behaviour:

```elixir
defmodule MyApp.FlameOnHandler do
  use FlameOn.Client.EventHandler

  @impl true
  def handle([:my_app, :process_batch, :start], _measurements, %{batch_id: id}) do
    {:capture, %{event_name: "batch.process", event_identifier: "batch-#{id}"}}
  end

  # Unhandled events automatically fall through to the Default handler.
  # To skip an event explicitly:
  def handle([:phoenix, :router_dispatch, :start], _measurements, _metadata), do: :skip

  @impl true
  def default_threshold_ms([:my_app, :process_batch, :start]), do: 5_000
  # Unhandled events fall through to the Default handler's thresholds.
end
```

```elixir
config :flame_on_client,
  event_handler: MyApp.FlameOnHandler,
  events: [
    {[:my_app, :process_batch, :start], threshold_ms: 5_000},
    [:phoenix, :router_dispatch, :start]
  ]
```

The `handle/3` callback returns either `{:capture, info}` to trace the calling process, or `:skip` to ignore the event. The `default_threshold_ms/1` callback provides the default duration threshold (in ms) for each event type. Any clauses you don't define for either callback fall through to `FlameOn.Client.EventHandler.Default`.

## Public API

```elixir
# Returns the current configuration as a map
FlameOn.Client.config()

# Returns the number of processes currently being traced
FlameOn.Client.active_traces()
```

## Custom Shipper Adapters

The shipper uses an adapter pattern. Implement `FlameOn.Client.Shipper.Behaviour` to change how traces are delivered:

```elixir
defmodule MyApp.FlameOnShipper do
  @behaviour FlameOn.Client.Shipper.Behaviour

  @impl true
  def send_batch(batch, config) do
    # batch is a list of trace maps from the Collector. Each trace has:
    #   :trace_id, :event_name, :event_identifier,
    #   :duration_us, :captured_at (unix microseconds),
    #   :samples (list of %{stack_path: "A;B;C", duration_us: 123})
    #
    # The default Grpc adapter encodes these into pprof Profiles and sends
    # them over gRPC. Custom adapters receive the raw nested traces.
    :ok
  end
end
```

```elixir
config :flame_on_client,
  shipper_adapter: MyApp.FlameOnShipper
```

## Architecture

```
Telemetry Event
      │  (sync call — caller blocks
      │   until tracing is active)
      ▼
┌─────────────┐  start_session   ┌─────────────────────────┐
│  Collector   │────────────────►│  TraceSessionSupervisor  │
│  (GenServer) │                 │  (DynamicSupervisor)     │
│              │                 └────────────┬─────────────┘
│  - sampling  │                              │ spawns
│  - coordi-   │                              ▼
│    nation    │                 ┌──────────────────────────┐
└──────┬───────┘                │  TraceSession            │
       │                        │  (GenServer, per trace)   │
       │ :stop event            │                          │
       │ ──► cast :stop ───────►│  ◄── :erlang.trace/3     │
       │                        │      :call, :return,     │
       │ monitors session       │      :in, :out           │
       │ ◄── :DOWN ────────────│                          │
       │                        │  - stack building        │
       │                        │  - finalize & collapse   │
       │                        │  - threshold filter      │
       │                        │  - profile filter        │
       │                        └────────────┬─────────────┘
       │                                     │
       │                                     ▼
       │                        ┌───────────────┐  gRPC
       │                        │   Shipper     │──────►  flameon.ai
       │                        │  (GenServer)  │  pprof + Bearer
       │                        │  - batching   │
       │                        │  - pprof      │
       │                        │    encoding   │
       │                        │  - backpressure│
       │                        └───────────────┘
```

### Supervision Tree

```
FlameOn.Client.Supervisor (one_for_one)
├── GRPC.Client.Supervisor (DynamicSupervisor)
├── FlameOn.Client.Shipper
├── FlameOn.Client.TraceSessionSupervisor (DynamicSupervisor)
└── FlameOn.Client.Collector
```

Children start in order: the gRPC DynamicSupervisor first, then the Shipper (which opens gRPC connections), then the TraceSessionSupervisor (which manages per-trace processes), then the Collector (which coordinates telemetry events and spawns trace sessions).

## Wire Format

The trace gRPC adapter (`FlameOn.Client.Shipper.Grpc`) calls the `FlameOnIngest.Ingest` RPC on FlameOn. Authentication is sent as gRPC metadata (`authorization: Bearer <api_key>`).

The shared protobuf schema also defines FlameOn's runtime error ingestion service (`FlameOnErrorIngest.IngestErrors`), which this client now uses for manual error reporting.

### Protobuf schema

The service is defined in `priv/protos/flame_on.proto`:

```protobuf
service FlameOnIngest {
  rpc Ingest(IngestRequest) returns (IngestResponse);
}

service FlameOnErrorIngest {
  rpc IngestErrors(IngestErrorsRequest) returns (IngestErrorsResponse);
}

message IngestRequest {
  repeated TraceProfile traces = 1;
}

message TraceProfile {
  string trace_id = 1;
  string event_name = 3;
  string event_identifier = 4;
  perftools.profiles.Profile profile = 5;
}

message IngestResponse {
  bool success = 1;
  int32 ingested = 2;
  string message = 3;
}
```

Each `TraceProfile` wraps trace metadata alongside a standard [pprof `Profile`](https://github.com/google/pprof/blob/main/proto/profile.proto). The pprof profile contains:

- **`string_table`** — deduplicated function names (index 0 is always `""`)
- **`function`** — one entry per unique function frame
- **`location`** — one entry per function, linking to its `function` entry
- **`sample`** — one entry per collapsed stack path, with `location_id` references (in pprof convention: innermost/leaf frame first, outermost/root frame last) and `[self_us, total_us]` values
- **`sample_type`** — declares the value types as `self_us` and `total_us` in `microseconds`

Stack paths use semicolons as delimiters in the collapsed format, matching the standard used by flame graph tools. Sleep time (process scheduled out) appears as `SLEEP` in the path.

## Development

```bash
mix deps.get
mix test
mix format
```

### Regenerating protobuf modules

If the `.proto` files in `priv/protos/` change:

```bash
mix protobuf.generate --output-path=lib/flame_on --include-path=. --include-path=priv/protos --plugin=ProtobufGenerate.Plugins.GRPC priv/protos/flame_on.proto
```
