defmodule FlameOn.Client.EventHandler.DefaultTest do
  use ExUnit.Case, async: true

  alias FlameOn.Client.EventHandler.Default

  describe "Phoenix router_dispatch" do
    test "captures with route pattern from phoenix_route" do
      event = [:phoenix, :router_dispatch, :start]
      measurements = %{}

      metadata = %{
        conn: %{
          method: "GET",
          request_path: "/api/orders/123",
          private: %{phoenix_route: "/api/orders/:id"}
        }
      }

      assert {:capture, info} = Default.handle(event, measurements, metadata)
      assert info.event_name == "phoenix.request"
      assert info.event_identifier == "GET /api/orders/:id"
    end

    test "captures with route pattern from plug_route" do
      event = [:phoenix, :router_dispatch, :start]
      measurements = %{}

      metadata = %{
        conn: %{
          method: "POST",
          request_path: "/api/users",
          private: %{plug_route: {"/api/users", :handler}}
        }
      }

      assert {:capture, info} = Default.handle(event, measurements, metadata)
      assert info.event_name == "phoenix.request"
      assert info.event_identifier == "POST /api/users"
    end

    test "falls back to request_path when no route pattern available" do
      event = [:phoenix, :router_dispatch, :start]
      measurements = %{}

      metadata = %{
        conn: %{
          method: "GET",
          request_path: "/api/fallback",
          private: %{}
        }
      }

      assert {:capture, info} = Default.handle(event, measurements, metadata)
      assert info.event_name == "phoenix.request"
      assert info.event_identifier == "GET /api/fallback"
    end
  end

  describe "Oban job" do
    test "captures with worker name" do
      event = [:oban, :job, :start]
      measurements = %{}
      metadata = %{job: %{worker: "MyApp.Workers.SendEmail"}}

      assert {:capture, info} = Default.handle(event, measurements, metadata)
      assert info.event_name == "oban.job"
      assert info.event_identifier == "\"MyApp.Workers.SendEmail\""
    end

    test "captures with module worker" do
      event = [:oban, :job, :start]
      measurements = %{}
      metadata = %{job: %{worker: MyApp.Workers.ProcessOrder}}

      assert {:capture, info} = Default.handle(event, measurements, metadata)
      assert info.event_name == "oban.job"
      assert info.event_identifier == "MyApp.Workers.ProcessOrder"
    end
  end

  describe "LiveView handle_event" do
    test "captures with view module and event name" do
      event = [:phoenix, :live_view, :handle_event, :start]
      measurements = %{}
      metadata = %{socket: %{view: MyAppWeb.DashboardLive}, event: "filter_changed"}

      assert {:capture, info} = Default.handle(event, measurements, metadata)
      assert info.event_name == "live_view.event"
      assert info.event_identifier == "MyAppWeb.DashboardLive.filter_changed"
    end
  end

  describe "LiveComponent handle_event" do
    test "captures with component module and event name" do
      event = [:phoenix, :live_component, :handle_event, :start]
      measurements = %{}
      metadata = %{component: MyAppWeb.SearchComponent, socket: %{}, event: "search"}

      assert {:capture, info} = Default.handle(event, measurements, metadata)
      assert info.event_name == "live_component.event"
      assert info.event_identifier == "MyAppWeb.SearchComponent.search"
    end
  end

  describe "Absinthe operation" do
    test "captures with operation name from options" do
      event = [:absinthe, :execute, :operation, :start]
      measurements = %{}
      metadata = %{options: %{document: %{name: "GetOrders"}}}

      assert {:capture, info} = Default.handle(event, measurements, metadata)
      assert info.event_name == "graphql.operation"
      assert info.event_identifier == "GetOrders"
    end

    test "captures anonymous when no operation name" do
      event = [:absinthe, :execute, :operation, :start]
      measurements = %{}
      metadata = %{options: %{document: %{name: nil}}}

      assert {:capture, info} = Default.handle(event, measurements, metadata)
      assert info.event_name == "graphql.operation"
      assert info.event_identifier == "anonymous"
    end

    test "captures anonymous when no document" do
      event = [:absinthe, :execute, :operation, :start]
      measurements = %{}
      metadata = %{options: %{}}

      assert {:capture, info} = Default.handle(event, measurements, metadata)
      assert info.event_name == "graphql.operation"
      assert info.event_identifier == "anonymous"
    end
  end

  describe "catch-all" do
    test "skips unknown events" do
      assert :skip == Default.handle([:unknown, :event], %{}, %{})
    end

    test "skips events with matching prefix but wrong shape" do
      assert :skip == Default.handle([:some, :random, :thing], %{}, %{})
    end
  end

  describe "default_threshold_ms/1" do
    test "returns 500 for phoenix router_dispatch" do
      assert Default.default_threshold_ms([:phoenix, :router_dispatch, :start]) == 500
    end

    test "returns 30_000 for oban job" do
      assert Default.default_threshold_ms([:oban, :job, :start]) == 30_000
    end

    test "returns 200 for live_view handle_event" do
      assert Default.default_threshold_ms([:phoenix, :live_view, :handle_event, :start]) == 200
    end

    test "returns 200 for live_component handle_event" do
      assert Default.default_threshold_ms([:phoenix, :live_component, :handle_event, :start]) ==
               200
    end

    test "returns 1000 for absinthe execute operation" do
      assert Default.default_threshold_ms([:absinthe, :execute, :operation, :start]) == 1_000
    end

    test "returns global default of 100 for unknown events" do
      assert Default.default_threshold_ms([:unknown, :event, :start]) == 100
    end
  end

  describe "EventHandler __using__ macro" do
    defmodule CustomHandler do
      use FlameOn.Client.EventHandler

      def handle([:custom, :event, :start], _measurements, %{name: name}) do
        {:capture, %{event_name: "custom.event", event_identifier: name}}
      end
    end

    test "custom handler matches custom events" do
      assert {:capture, info} =
               CustomHandler.handle([:custom, :event, :start], %{}, %{name: "test"})

      assert info.event_name == "custom.event"
      assert info.event_identifier == "test"
    end

    test "custom handler falls through to Default for unmatched events" do
      event = [:phoenix, :router_dispatch, :start]

      metadata = %{
        conn: %{
          method: "GET",
          request_path: "/test",
          private: %{phoenix_route: "/test"}
        }
      }

      assert {:capture, info} = CustomHandler.handle(event, %{}, metadata)
      assert info.event_name == "phoenix.request"
    end

    test "custom handler returns :skip for completely unknown events" do
      assert :skip == CustomHandler.handle([:totally, :unknown], %{}, %{})
    end
  end
end
