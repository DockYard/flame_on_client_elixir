import Config

config :flame_on_client,
  capture: false,
  api_key: nil,
  sample_rate: 0.01,
  function_length_threshold: 0.01,
  events: [
    [:phoenix, :router_dispatch, :start],
    [:oban, :job, :start],
    [:phoenix, :live_view, :handle_event, :start],
    [:phoenix, :live_component, :handle_event, :start],
    [:absinthe, :execute, :operation, :start]
  ]

import_config "#{config_env()}.exs"
