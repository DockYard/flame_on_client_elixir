defmodule FlameOnClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :flame_on_client,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {FlameOn.Client.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.0"},
      {:plug, "~> 1.16"},
      {:telemetry, "~> 1.0"},
      {:mox, "~> 1.0", only: :test},
      {:castore, "~> 1.0"},
      {:grpc, "~> 0.11"},
      {:protobuf, "~> 0.16"},
      {:protobuf_generate, "~> 0.2", only: :dev}
    ]
  end
end
