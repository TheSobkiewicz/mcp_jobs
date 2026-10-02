import Config

config :mcp_oban, ecto_repos: [MCPOban.Test.Repo]

config :mcp_oban, MCPOban.Test.Repo,
  database: "mcp_oban_test",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning
