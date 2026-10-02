import Config

config :mcpo, ecto_repos: [MCPO.Test.Repo]

config :mcpo, MCPO.Test.Repo,
  database: "mcpo_test",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning
