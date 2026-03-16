defmodule FlameOn.Client.ErrorShipper.Behaviour do
  @callback send_batch(batch :: list(FlameOn.ErrorEvent.t()), config :: map()) ::
              :ok | {:error, term()}
end
