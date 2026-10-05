defmodule MCPJobs.Cleaner do
  @moduledoc """
  An Oban worker that deletes old terminal tasks. It never deletes `:working` tasks.

  Set the retention time in milliseconds. The default is 24 hours:

      config :mcp_jobs, task_retention: :timer.hours(24)

  Run it with the Oban Cron plugin:

      config :my_app, Oban,
        plugins: [{Oban.Plugins.Cron, crontab: [{"@hourly", MCPJobs.Cleaner}]}]

  The job goes to the `:default` queue. If your app does not run that queue, set
  a queue that it runs: `{"@hourly", MCPJobs.Cleaner, queue: :maintenance}`.
  Otherwise the job never runs, and old tasks are never deleted.
  """

  use Oban.Worker, queue: :default, unique: [period: 60]

  @default_retention :timer.hours(24)

  @impl Oban.Worker
  def perform(%Oban.Job{conf: conf}) do
    retention = Application.get_env(:mcp_jobs, :task_retention, @default_retention)
    cutoff = DateTime.add(DateTime.utc_now(), -retention, :millisecond)

    {:ok, MCPJobs.Repository.delete_terminal_before(conf, cutoff)}
  end
end
