import Config

config :flame_on_client,
  capture: false,
  capture_errors: false,
  logger_fallback: false,
  api_key: nil,
  before_send: nil,
  environment: "production",
  service: "unknown",
  release: "unknown",
  sample_rate: 0.01,
  function_length_threshold: 0.01,
  error_flush_interval_ms: 5_000,
  error_dedupe_window_ms: 5_000,
  max_error_batch_size: 50,
  max_error_buffer_size: 500,
  max_string_length: 2_000,
  max_breadcrumbs: 50,
  events: [
    [:phoenix, :router_dispatch, :start],
    [:oban, :job, :start],
    [:phoenix, :live_view, :handle_event, :start],
    [:phoenix, :live_component, :handle_event, :start],
    [:absinthe, :execute, :operation, :start]
  ]

import_config "#{config_env()}.exs"
