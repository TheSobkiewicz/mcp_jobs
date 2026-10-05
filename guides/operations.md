# Core API, telemetry and cleanup

## Use without an MCP library

```elixir
{:ok, %MCPJobs.Task{task_id: task_id}} =
  MCPJobs.enqueue(MyApp.Workers.GenerateReport, %{report_id: 1}, owner: %{"user_id" => 7})

MCPJobs.status(task_id)
#=> {:ok, %{status: :working}}
#=> {:ok, %{status: :completed, result: %{"url" => "..."}}}
#=> {:ok, %{status: :failed, error: %{"message" => "..."}}}
#=> {:ok, %{status: :cancelled}}

MCPJobs.cancel(task_id)
```

To make an adapter for a different MCP server, use `MCPJobs.enqueue/3`, `MCPJobs.get/2`, and `MCPJobs.cancel/2`. For clients that cannot poll, `MCPJobs.await/2` waits until the task is done.

### Duplicate requests

Give the MCP task ID as `task_id:`. If a task with this ID already exists for the same worker and owner, `enqueue/3` returns it and does not insert a second job. If the worker or the owner is different, it returns `{:error, :already_exists}`, so one owner never gets another owner's task. A unique index in the database enforces this, also for requests that arrive at the same time.

## Telemetry

MCPJobs sends these events:

| Event                            | Measurements   |
| -------------------------------- | -------------- |
| `[:mcp_jobs, :task, :started]`   | `:system_time` |
| `[:mcp_jobs, :task, :completed]` | `:duration`    |
| `[:mcp_jobs, :task, :failed]`    | `:duration`    |
| `[:mcp_jobs, :task, :cancelled]` | `:duration`    |
| `[:mcp_jobs, :task, :progress]`  | `:system_time` |

`:duration` is the time from the task start to the status change, in native time units. `:progress` is sent when a working task gets new progress. The metadata of all events is `:task_id`, `:oban_job_id`, `:worker`, and `:oban` (the Oban instance name).

For retries, attempts, and queue times, use the Oban telemetry events.

## Cleanup

`MCPJobs.Cleaner` deletes completed, failed, and cancelled tasks that are older than the retention time. It never deletes `working` tasks. Run it with the Oban Cron plugin:

```elixir
config :my_app, Oban,
  plugins: [{Oban.Plugins.Cron, crontab: [{"@hourly", MCPJobs.Cleaner}]}]

config :mcp_jobs, task_retention: :timer.hours(24)
```

The Cleaner job goes to the `:default` queue. If your app does not run that queue, set a queue that it runs, for example `{"@hourly", MCPJobs.Cleaner, queue: :maintenance}`. Otherwise old tasks are never deleted.
