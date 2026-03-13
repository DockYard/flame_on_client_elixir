defmodule FlameOn.Client.EventHandler do
  @type capture_info :: %{
          required(:event_name) => String.t(),
          required(:event_identifier) => String.t()
        }

  @callback handle(
              event :: [atom()],
              measurements :: map(),
              metadata :: map()
            ) :: {:capture, capture_info()} | :skip

  @callback default_threshold_ms(event :: [atom()]) :: non_neg_integer()

  defmacro __using__(_opts) do
    quote do
      @behaviour FlameOn.Client.EventHandler
      @before_compile FlameOn.Client.EventHandler
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def handle(event, measurements, metadata) do
        FlameOn.Client.EventHandler.Default.handle(event, measurements, metadata)
      end

      def default_threshold_ms(event) do
        FlameOn.Client.EventHandler.Default.default_threshold_ms(event)
      end
    end
  end
end
