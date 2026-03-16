defmodule FlameOn.Client.ErrorEventTest do
  use ExUnit.Case, async: true

  alias FlameOn.Client.ErrorEvent

  test "build_exception_event/2 normalizes a rescued exception" do
    exception = %RuntimeError{message: "boom"}

    {error, stacktrace} =
      try do
        raise exception
      rescue
        error -> {error, __STACKTRACE__}
      end

    event =
      ErrorEvent.build_exception_event(error,
        stacktrace: stacktrace,
        service: "my_app",
        environment: "prod",
        release: "1.2.3",
        route: "GET /users/:id",
        trace_id: "123e4567-e89b-12d3-a456-426614174000",
        request: %{
          method: "GET",
          url: "https://example.test/users/123",
          route: "GET /users/:id",
          headers: %{"x-request-id" => "abc123"},
          remote_addr: "127.0.0.1"
        },
        user: %{id: 123, email: "dev@example.test"},
        tags: %{region: "test"},
        contexts: %{runtime: "beam"},
        breadcrumbs: [%{category: "request", message: "started", level: "info"}]
      )

    assert %FlameOn.ErrorEvent{} = event
    assert event.platform == "elixir"
    assert event.environment == "prod"
    assert event.service == "my_app"
    assert event.release == "1.2.3"
    assert event.route == "GET /users/:id"
    assert event.message == "boom"
    assert event.handled
    assert event.trace_id == "123e4567-e89b-12d3-a456-426614174000"
    assert [%FlameOn.Exception{type: "RuntimeError", value: "boom"}] = event.exceptions
    assert %FlameOn.RequestContext{method: "GET", route: "GET /users/:id"} = event.request
    assert [%FlameOn.KeyValue{key: "region", value: "test"}] = event.tags
    assert [%FlameOn.KeyValue{key: "runtime", value: "beam"}] = event.contexts

    assert [%FlameOn.Breadcrumb{category: "request", message: "started", level: "info"}] =
             event.breadcrumbs

    [frame | _] = hd(event.exceptions).stack_trace.frames
    assert frame.function != ""
  end

  test "build_message_event/2 creates handled message event" do
    event =
      ErrorEvent.build_message_event("payment timed out",
        service: "my_app",
        fingerprint: ["payments", "timeout"],
        handled: false,
        severity: "warning"
      )

    assert %FlameOn.ErrorEvent{} = event
    assert event.message == "payment timed out"
    assert event.service == "my_app"
    assert event.severity == "warning"
    refute event.handled
    assert event.fingerprint == ["payments", "timeout"]
    assert event.exceptions == []
  end

  test "redacts sensitive request and context values" do
    {error, stacktrace} =
      try do
        raise "boom"
      rescue
        error -> {error, __STACKTRACE__}
      end

    event =
      ErrorEvent.build_exception_event(error,
        stacktrace: stacktrace,
        request: %{
          method: "POST",
          url: "https://example.test/login",
          headers: %{
            "authorization" => "Bearer secret-token",
            "x-request-id" => "abc123"
          }
        },
        contexts: %{password: "super-secret", token: "abc", safe: "ok"},
        redact_fields: ["authorization", :password, :token]
      )

    assert Enum.any?(
             event.request.headers,
             &(&1.key == "authorization" and &1.value == "[REDACTED]")
           )

    assert Enum.any?(event.request.headers, &(&1.key == "x-request-id" and &1.value == "abc123"))
    assert Enum.any?(event.contexts, &(&1.key == "password" and &1.value == "[REDACTED]"))
    assert Enum.any?(event.contexts, &(&1.key == "token" and &1.value == "[REDACTED]"))
    assert Enum.any?(event.contexts, &(&1.key == "safe" and &1.value == "ok"))
  end

  test "truncates oversized strings and breadcrumbs" do
    event =
      ErrorEvent.build_message_event(String.duplicate("a", 300),
        max_string_length: 32,
        max_breadcrumbs: 2,
        breadcrumbs: [
          %{category: "one", message: String.duplicate("b", 100)},
          %{category: "two", message: String.duplicate("c", 100)},
          %{category: "three", message: String.duplicate("d", 100)}
        ],
        contexts: %{oversized: String.duplicate("e", 100)}
      )

    assert String.length(event.message) == 32
    assert length(event.breadcrumbs) == 2
    assert Enum.all?(event.breadcrumbs, &(String.length(&1.message) == 32))
    assert Enum.any?(event.contexts, &(&1.key == "oversized" and String.length(&1.value) == 32))
  end
end
