import Config

config :flame_on_client,
  shipper_adapter: FlameOn.Client.Shipper.MockAdapter,
  sample_rate: 1.0
