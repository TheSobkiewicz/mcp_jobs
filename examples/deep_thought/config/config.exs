import Config

config :deep_thought, ecto_repos: [DeepThought.Repo]

config :deep_thought, DeepThought.Repo,
  database: "deep_thought_dev",
  hostname: "localhost"

config :deep_thought, Oban,
  repo: DeepThought.Repo,
  queues: [thinking: 5],
  plugins: [{Oban.Plugins.Cron, crontab: [{"@hourly", MCPJobs.Cleaner, queue: :thinking}]}]

config :mcp_jobs, task_retention: :timer.hours(24)

config :logger, level: :warning
