defmodule FlameOn.Client.PhoenixPlugTest do
  use ExUnit.Case, async: false

  import Mox

  alias FlameOn.Client.ErrorShipper
  alias FlameOn.Client.PhoenixPlug

  setup :verify_on_exit!

  test "captures an exception with request context and reraises it" do
    test_pid = self()

    FlameOn.Client.ErrorShipper.MockAdapter
    |> expect(:send_batch, fn [%FlameOn.ErrorEvent{} = event], _config ->
      send(test_pid, {:captured, event})
      :ok
    end)

    pid =
      start_supervised!(
        {ErrorShipper,
         [
           name: FlameOn.Client.ErrorShipper,
           flush_interval_ms: 50,
           max_batch_size: 1,
           shipper_adapter: FlameOn.Client.ErrorShipper.MockAdapter,
           api_key: "test-key",
           server_url: "localhost",
           use_ssl: false
         ]},
        id: :phoenix_plug_error_shipper
      )

    allow(FlameOn.Client.ErrorShipper.MockAdapter, self(), pid)

    conn =
      Plug.Test.conn("GET", "/users/123")
      |> Map.put(:host, "example.test")
      |> Map.put(:scheme, :https)
      |> Plug.Conn.put_req_header("x-request-id", "abc123")
      |> Plug.Conn.assign(:current_user, %{id: 123, email: "dev@example.test"})
      |> put_in([Access.key(:private), :phoenix_route], "GET /users/:id")

    assert_raise RuntimeError, "boom", fn ->
      PhoenixPlug.call(conn, fn _conn ->
        raise "boom"
      end)
    end

    assert_receive {:captured, event}, 1000
    assert event.message == "boom"
    refute event.handled
    assert event.request.method == "GET"
    assert event.request.url == "https://example.test/users/123"
    assert event.request.route == "GET /users/:id"
    assert event.route == "GET /users/:id"
    assert event.user.id == "123"
    assert event.user.email == "dev@example.test"
    assert Enum.any?(event.request.headers, &(&1.key == "x-request-id" and &1.value == "abc123"))
  end
end
