defmodule MCPOban.MixProject do
  use Mix.Project

  def project do
    [
      app: :mcp_oban,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MCPOban.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:oban, "~> 2.24"},
      {:ecto_sql, "~> 3.14"},
      {:telemetry, "~> 1.4"},
      {:ex_mcp, "~> 1.5", optional: true},
      {:fastest_mcp, "~> 0.3.2", optional: true},
      {:postgrex, "~> 0.22", only: [:dev, :test]},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
