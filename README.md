# MCPO

Runs MCP tool calls as [Oban](https://hex.pm/packages/oban) jobs.

An MCP client calls a tool. The server gives back a task ID at once, and Oban does the work in the background. The client asks for the task status until the task is done. The MCP task status follows the Oban job state:

| Oban job state                                     | MCP task status |
| -------------------------------------------------- | --------------- |
| `available`, `scheduled`, `executing`, `retryable` | `working`       |
| `completed`                                        | `completed`     |
| `discarded` (all attempts failed)                  | `failed`        |
| `cancelled`, or the job is deleted                 | `cancelled`     |

A retry does not make a task fail. The task fails only when Oban stops retrying the job.

MCPO does not implement the MCP protocol. It includes an adapter for [ExMCP](https://hex.pm/packages/ex_mcp). The core API does not depend on an MCP library.

## Installation

```elixir
def deps do
  [
    {:mcpo, "~> 0.1"}
  ]
end
```

MCPO uses the repo of your Oban instance. Add a migration:

```elixir
defmodule MyApp.Repo.Migrations.AddMCPOTasks do
  use Ecto.Migration

  def up, do: MCPO.Migration.up()
  def down, do: MCPO.Migration.down()
end
```

If Oban uses a prefix, pass the same prefix: `MCPO.Migration.up(prefix: "private")`.

If your Oban instance does not have the name `Oban`, set the name:

```elixir
config :mcpo, oban: MyApp.Oban
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

> **Note:** Oban marks the job `completed` first, and then MCPO saves the result from the Oban telemetry event. If the node stops between these two steps, the task becomes `completed` with no result.

## Use with ExMCP

```elixir
defmodule MyApp.MCPServer do
  use MCPO.ExMCP

  @impl ExMCP.Server.Handler
  def handle_call_tool("generate_report", arguments, state) do
    create_task("generate_report", MyApp.Workers.GenerateReport, arguments, state)
  end
end
```

`use MCPO.ExMCP` is `use ExMCP.Server.Handler` with the MCPO task store. It also imports `create_task/4`. Other handler options are passed on to ExMCP.

ExMCP then answers `tasks/get` and `tasks/cancel` from the MCPO table:

- A completed task returns its result as a tool call result. The result map is in `structuredContent`, and as JSON text in `content`. If your result already has a `"content"` key, it is sent without change.
- A failed task returns a JSON-RPC error.
- Each task is bound to the ExMCP owner (principal, tenant, and audience). Other owners cannot read or cancel it.

### Clients without tasks

Many clients do not support the MCP Tasks extension yet. For example, the MCP Inspector uses the TypeScript SDK, and its latest protocol is `2025-11-25`. For these clients, `create_task/4` waits for the Oban job and returns the tool result directly. The work still runs in Oban, with retries.

- A failed or cancelled job returns a tool result with `"isError": true`.
- If the job does not finish in `:wait_timeout` (9 seconds by default), MCPO cancels the task and returns an error result.
- While the call waits, it is blocked. Over HTTP, ExMCP stops a handler call after `:handler_call_timeout` (10 seconds by default). For longer jobs, raise both values:

  ```elixir
  use MCPO.ExMCP, task_store_opts: [wait_timeout: 60_000]

  # and on the plug:
  Plug.Cowboy.http(ExMCP.HttpPlug, [handler: MyApp.MCPServer, handler_call_timeout: 65_000], port: 4000)
  ```

- Over stdio, other requests on the same connection wait.

Declare the tool with `"execution" => %{"taskSupport" => "optional"}`, so that both kinds of client can call it.

A raw ExMCP handler answers `initialize` with no capabilities. Older clients then do not ask for tools. Implement `handle_initialize/2` and return `"capabilities" => %{"tools" => %{}}`. See `examples/report_server/lib/report_server/mcp_server.ex`.

### Limits

- MCPO supports the MCP Tasks extension (spec 2026-07-28). Older clients get the direct result described above, not a task.
- The `input_required` status is not supported.
- MCPO does not send `notifications/tasks`, so clients must poll with `tasks/get`.

## Use without an MCP library

```elixir
{:ok, %MCPO.Task{task_id: task_id}} =
  MCPO.enqueue(MyApp.Workers.GenerateReport, %{report_id: 1}, owner: %{"user_id" => 7})

MCPO.status(task_id)
#=> {:ok, %{status: :working}}
#=> {:ok, %{status: :completed, result: %{"url" => "..."}}}
#=> {:ok, %{status: :failed, error: %{"message" => "..."}}}
#=> {:ok, %{status: :cancelled}}

MCPO.cancel(task_id)
```

To make an adapter for a different MCP server, use `MCPO.enqueue/3`, `MCPO.get/2`, and `MCPO.cancel/2`. For clients that cannot poll, `MCPO.await/2` waits until the task is done.

### Duplicate requests

Give the MCP task ID as `task_id:`. If a task with this ID already exists, `enqueue/3` returns it and does not insert a second job. A unique index in the database enforces this, also for requests that arrive at the same time.

## Cancellation

`MCPO.cancel/2` sets the task to `cancelled` at once.

- **The job waits to run:** Oban cancels the job.
- **The job is running:** Oban does not stop it. The BEAM cannot safely stop any code at any point, so the worker must stop by itself. A long worker should check `MCPO.cancelled?/1` between steps:

  ```elixir
  def perform(%Oban.Job{} = job) do
    Enum.reduce_while(steps(), :ok, fn step, :ok ->
      if MCPO.cancelled?(job) do
        {:halt, {:cancel, :mcp_task_cancelled}}
      else
        do_step(step)
        {:cont, :ok}
      end
    end)
  end
  ```

  If the worker does not stop, it runs to the end, but its result is not saved. The task stays `cancelled`.

- **Kill the job:** `MCPO.cancel(task_id, kill: true)` makes Oban kill a running job. The process stops at once and cannot clean up.

With ExMCP, use `use MCPO.ExMCP, task_store_opts: [kill: true]` to kill running jobs on `tasks/cancel`.

## Races

Each status change is one database update with the condition `WHERE status = 'working'`. The first change wins, and a terminal status never changes. For example, if a job completes while a client cancels it, the task is either `completed` or `cancelled`, never both.

## Telemetry

MCPO sends these events:

| Event                            | Measurements   |
| -------------------------------- | -------------- |
| `[:mcpo, :task, :started]`   | `:system_time` |
| `[:mcpo, :task, :completed]` | `:duration`    |
| `[:mcpo, :task, :failed]`    | `:duration`    |
| `[:mcpo, :task, :cancelled]` | `:duration`    |

`:duration` is the time from the task start to the status change, in native time units. The metadata of all events is `:task_id`, `:oban_job_id`, and `:worker`.

For retries, attempts, and queue times, use the Oban telemetry events.

## Cleanup

`MCPO.Cleaner` deletes completed, failed, and cancelled tasks that are older than the retention time. It never deletes `working` tasks. Run it with the Oban Cron plugin:

```elixir
config :my_app, Oban,
  plugins: [{Oban.Plugins.Cron, crontab: [{"@hourly", MCPO.Cleaner}]}]

config :mcpo, task_retention: :timer.hours(24)
```

## Example

`examples/report_server` is a small app with an ExMCP server and one tool. Its demo calls the tool, waits for the result, and cancels a running job:

```sh
cd examples/report_server
mix deps.get
mix ecto.create && mix ecto.migrate
mix run demo.exs
```

To use it from another MCP client, start it over HTTP on port 4000:

```sh
mix run --no-halt serve.exs
npx @modelcontextprotocol/inspector --cli http://localhost:4000/ --transport http \
  --method tools/call --tool-name generate_report --tool-arg steps=3
```

## Development

Tests need a local Postgres.

```sh
mix test
```
