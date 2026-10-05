import Config

config :report_server, ecto_repos: [ReportServer.Repo]

config :report_server, ReportServer.Repo,
  database: "report_server_dev",
  hostname: "localhost"

config :report_server, Oban,
  repo: ReportServer.Repo,
  queues: [reports: 5],
  plugins: [{Oban.Plugins.Cron, crontab: [{"@hourly", MCPJobs.Cleaner, queue: :reports}]}]

config :mcp_jobs, task_retention: :timer.hours(24)

config :logger, level: :warning
