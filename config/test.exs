import Config

config :mcp_jobs, ecto_repos: [MCPJobs.Test.Repo]

config :mcp_jobs, MCPJobs.Test.Repo,
  database: "mcp_jobs_test",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning
