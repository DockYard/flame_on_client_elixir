defmodule FlameOn.Client.Shipper.Behaviour do
  @callback send_batch(batch :: list(map()), config :: map()) :: :ok | {:error, term()}
end
