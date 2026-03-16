defmodule FlameOnProtoTest do
  use ExUnit.Case, async: true

  test "supports trace and error ingestion protobuf messages" do
    request = %FlameOn.IngestErrorsRequest{
      events: [
        %FlameOn.ErrorEvent{
          event_id: "evt_123",
          platform: "elixir",
          environment: "test",
          service: "flame_on_client",
          route: "GET /health",
          release: "0.1.0",
          severity: "error",
          message: "boom",
          handled: false,
          trace_id: "123e4567-e89b-12d3-a456-426614174000",
          fingerprint: ["RuntimeError", "GET /health"],
          exceptions: [
            %FlameOn.Exception{
              type: "RuntimeError",
              value: "boom",
              stack_trace: %FlameOn.StackTrace{
                frames: [
                  %FlameOn.StackFrame{
                    function: "call/2",
                    module: "MyApp.Endpoint",
                    file: "lib/my_app/endpoint.ex",
                    line: 42,
                    in_app: true
                  }
                ]
              }
            }
          ],
          request: %FlameOn.RequestContext{
            method: "GET",
            url: "https://example.test/health",
            route: "GET /health",
            headers: [%FlameOn.KeyValue{key: "x-request-id", value: "abc123"}],
            remote_addr: "127.0.0.1"
          },
          user: %FlameOn.UserContext{id: "123", email: "dev@example.test"},
          breadcrumbs: [
            %FlameOn.Breadcrumb{
              category: "request",
              message: "started",
              type: "default",
              level: "info",
              data: [%FlameOn.KeyValue{key: "method", value: "GET"}]
            }
          ],
          tags: [%FlameOn.KeyValue{key: "region", value: "test"}],
          contexts: [%FlameOn.KeyValue{key: "runtime", value: "beam"}]
        }
      ]
    }

    encoded = FlameOn.IngestErrorsRequest.encode(request)
    decoded = FlameOn.IngestErrorsRequest.decode(encoded)

    assert [%FlameOn.ErrorEvent{} = event] = decoded.events
    assert event.event_id == "evt_123"
    assert event.message == "boom"
    assert event.request.method == "GET"
    assert hd(event.exceptions).type == "RuntimeError"
    assert hd(hd(event.exceptions).stack_trace.frames).module == "MyApp.Endpoint"
  end

  test "defines error ingest gRPC service modules" do
    assert Code.ensure_loaded?(FlameOn.FlameOnErrorIngest.Service)
    assert Code.ensure_loaded?(FlameOn.FlameOnErrorIngest.Stub)
    assert FlameOn.FlameOnIngest.Service.__meta__(:name) == "flame_on.FlameOnIngest"
    assert FlameOn.FlameOnErrorIngest.Service.__meta__(:name) == "flame_on.FlameOnErrorIngest"
  end
end
