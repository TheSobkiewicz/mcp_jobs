defmodule ReportServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :report_server,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ReportServer.Application, []}
    ]
  end

  defp deps do
    [
      {:mcp_oban, path: "../.."},
      {:ex_mcp, "~> 1.5"},
      {:fastest_mcp, "~> 0.3"},
      {:oban, "~> 2.24"},
      {:postgrex, "~> 0.22"}
    ]
  end
end
