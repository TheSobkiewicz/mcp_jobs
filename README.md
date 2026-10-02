# MCPOban

Runs MCP tool calls as [Oban](https://hex.pm/packages/oban) jobs.

An MCP client calls a tool. The server gives back a task ID at once, and Oban does the work in the background. The client asks for the task status until the task is done. The MCP task status follows the Oban job state:

| Oban job state                                     | MCP task status |
| -------------------------------------------------- | --------------- |
| `available`, `scheduled`, `executing`, `retryable` | `working`       |
| `completed`                                        | `completed`     |
| `discarded` (all attempts failed)                  | `failed`        |
| `cancelled`, or the job is deleted                 | `cancelled`     |

A retry does not make a task fail. The task fails only when Oban stops retrying the job.

MCPOban does not implement the MCP protocol. It includes an adapter for [ExMCP](https://hex.pm/packages/ex_mcp). The core API does not depend on an MCP library.

## Installation

```elixir
def deps do
  [
    {:mcp_oban, "~> 0.1"}
  ]
end
```

MCPOban uses the repo of your Oban instance. Add a migration:

```elixir
defmodule MyApp.Repo.Migrations.AddMCPObanTasks do
  use Ecto.Migration

  def up, do: MCPOban.Migration.up()
  def down, do: MCPOban.Migration.down()
end
```

If Oban uses a prefix, pass the same prefix: `MCPOban.Migration.up(prefix: "private")`.

If your Oban instance does not have the name `Oban`, set the name:

```elixir
config :mcp_oban, oban: MyApp.Oban
```

## Write a worker

A worker is a plain `Oban.Worker`. It does not need to know about MCP:

```elixir
defmodule MyApp.Workers.GenerateReport do
  use Oban.Worker, queue: :reports, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"report_id" => report_id}}) do
    {:ok, %{"url" => MyApp.Reports.generate(report_id)}}
  end
end
```

The return value of `perform/1` becomes the task result:

- `{:ok, map}` completes the task and saves the map as the result.
- `{:ok, value}` saves `%{"value" => value}`.
- `:ok` completes the task with no result.
- `{:error, reason}` makes Oban retry the job. The task stays `working`.

The result is stored as JSON, so atom keys come back as strings. The result must be JSON-safe: for example, no tuples or PIDs.

> **Note:** Oban marks the job `completed` first, and then MCPOban saves the result from the Oban telemetry event. If the node stops between these two steps, the task becomes `completed` with no result.

## Use with ExMCP

```elixir
defmodule MyApp.MCPServer do
  use MCPOban.ExMCP

  @impl ExMCP.Server.Handler
  def handle_call_tool("generate_report", arguments, state) do
    create_task("generate_report", MyApp.Workers.GenerateReport, arguments, state)
  end
end
```

`use MCPOban.ExMCP` is `use ExMCP.Server.Handler` with the MCPOban task store. It also imports `create_task/4`. Other handler options are passed on to ExMCP.

ExMCP then answers `tasks/get` and `tasks/cancel` from the MCPOban table:

- A completed task returns its result as a tool call result. The result map is in `structuredContent`, and as JSON text in `content`. If your result already has a `"content"` key, it is sent without change.
- A failed task returns a JSON-RPC error.
- Each task is bound to the ExMCP owner (principal, tenant, and audience). Other owners cannot read or cancel it.

Limits:
- MCPOban supports the MCP Tasks extension (spec 2026-07-28). It does not support the older `tasks/list` and `tasks/result` methods.
- The `input_required` status is not supported.
- MCPOban does not send `notifications/tasks`, so clients must poll with `tasks/get`.

## Use without an MCP library

```elixir
{:ok, %MCPOban.Task{task_id: task_id}} =
  MCPOban.enqueue(MyApp.Workers.GenerateReport, %{report_id: 1}, owner: %{"user_id" => 7})

MCPOban.status(task_id)
#=> {:ok, %{status: :working}}
#=> {:ok, %{status: :completed, result: %{"url" => "..."}}}
#=> {:ok, %{status: :failed, error: %{"message" => "..."}}}
#=> {:ok, %{status: :cancelled}}

MCPOban.cancel(task_id)
```

To make an adapter for a different MCP server, use `MCPOban.enqueue/3`, `MCPOban.get/2`, and `MCPOban.cancel/2`.

### Duplicate requests

Give the MCP task ID as `task_id:`. If a task with this ID already exists, `enqueue/3` returns it and does not insert a second job. A unique index in the database enforces this, also for requests that arrive at the same time.

## Cancellation

`MCPOban.cancel/2` sets the task to `cancelled` at once.

- **The job waits to run:** Oban cancels the job.
- **The job is running:** Oban does not stop it. The BEAM cannot safely stop any code at any point, so the worker must stop by itself. A long worker should check `MCPOban.cancelled?/1` between steps:

  ```elixir
  def perform(%Oban.Job{} = job) do
    Enum.reduce_while(steps(), :ok, fn step, :ok ->
      if MCPOban.cancelled?(job) do
        {:halt, {:cancel, :mcp_task_cancelled}}
      else
        do_step(step)
        {:cont, :ok}
      end
    end)
  end
  ```

  If the worker does not stop, it runs to the end, but its result is not saved. The task stays `cancelled`.

- **Kill the job:** `MCPOban.cancel(task_id, kill: true)` makes Oban kill a running job. The process stops at once and cannot clean up.

With ExMCP, use `use MCPOban.ExMCP, task_store_opts: [kill: true]` to kill running jobs on `tasks/cancel`.

## Races

Each status change is one database update with the condition `WHERE status = 'working'`. The first change wins, and a terminal status never changes. For example, if a job completes while a client cancels it, the task is either `completed` or `cancelled`, never both.

## Telemetry

MCPOban sends these events:

| Event                            | Measurements   |
| -------------------------------- | -------------- |
| `[:mcp_oban, :task, :started]`   | `:system_time` |
| `[:mcp_oban, :task, :completed]` | `:duration`    |
| `[:mcp_oban, :task, :failed]`    | `:duration`    |
| `[:mcp_oban, :task, :cancelled]` | `:duration`    |

`:duration` is the time from the task start to the status change, in native time units. The metadata of all events is `:task_id`, `:oban_job_id`, and `:worker`.

For retries, attempts, and queue times, use the Oban telemetry events.

## Cleanup

`MCPOban.Cleaner` deletes completed, failed, and cancelled tasks that are older than the retention time. It never deletes `working` tasks. Run it with the Oban Cron plugin:

```elixir
config :my_app, Oban,
  plugins: [{Oban.Plugins.Cron, crontab: [{"@hourly", MCPOban.Cleaner}]}]

config :mcp_oban, task_retention: :timer.hours(24)
```

## Example

`examples/report_server` is a small app with an ExMCP server and one tool. Its demo calls the tool, waits for the result, and cancels a running job:

```sh
cd examples/report_server
mix deps.get
mix ecto.create && mix ecto.migrate
mix run demo.exs
```

## Development

Tests need a local Postgres.

```sh
mix test
```
