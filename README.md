# FlameOn Client

Production profiling client for Elixir applications. Captures per-process call stacks from telemetry events and ships them to [FlameOn](https://flameon.ai) for flame graph visualization.

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
    api_key: System.get_env("FLAMEON_API_KEY"),
    sample_rate: 0.01,
    function_length_threshold: 0.01
end
```

### All Options

| Key | Default | Description |
|-----|---------|-------------|
| `capture` | `false` | Must be `true` to enable tracing and shipping. When `false`, the client starts an empty supervisor and does nothing. |
| `api_key` | `nil` | API key from your FlameOn account, sent as gRPC metadata |
| `sample_rate` | `0.01` | Fraction of events to trace (0.0 to 1.0) |
| `function_length_threshold` | `0.01` | Remove children of blocks below this fraction of total request time (min: `0.005`) |
| `events` | *(see below)* | List of telemetry events to listen to |
| `event_handler` | `FlameOn.Client.EventHandler.Default` | Module that decides which events to capture |

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

The gRPC adapter (`FlameOn.Client.Shipper.Grpc`) calls the `FlameOnIngest.Ingest` RPC on FlameOn. Authentication is sent as gRPC metadata (`authorization: Bearer <token>`).

### Protobuf schema

The service is defined in `priv/protos/flameon.proto`:

```protobuf
service FlameOnIngest {
  rpc Ingest(IngestRequest) returns (IngestResponse);
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
mix protobuf.generate --output-path=lib priv/protos/**/*.proto
```
