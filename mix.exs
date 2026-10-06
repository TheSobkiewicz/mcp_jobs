defmodule MCPJobs.MixProject do
  use Mix.Project

  def project do
    [
      app: :mcp_jobs,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Turn Oban workers into MCP tools. Each tool call runs as an Oban job, and the client follows it as an MCP task.",
      source_url: "https://github.com/TheSobkiewicz/mcp_jobs",
      package: [
        licenses: ["MIT"],
        links: %{
          "GitHub" => "https://github.com/TheSobkiewicz/mcp_jobs",
          "Changelog" => "https://hexdocs.pm/mcp_jobs/changelog.html"
        },
        files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
      ],
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "guides/installation.md",
          "guides/workers.md",
          "guides/ex_mcp.md",
          "guides/fastest_mcp.md",
          "guides/operations.md",
          "CHANGELOG.md",
          "LICENSE"
        ],
        groups_for_extras: [Guides: ~r/guides\//]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MCPJobs.Application, []}
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
