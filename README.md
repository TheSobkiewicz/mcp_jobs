# MCPO

Runs MCP tool calls as [Oban](https://hex.pm/packages/oban) jobs.

An MCP client calls a tool. The server gives back a task ID at once, and Oban does the work in the background. The client asks for the task status until the task is done. The MCP task status follows the Oban job state:

| Oban job state                                     | MCP task status |
| -------------------------------------------------- | --------------- |
| `available`, `scheduled`, `executing`, `retryable`, `suspended` | `working` |
| `completed`                                        | `completed`     |
| `discarded` (all attempts failed)                  | `failed`        |
| `cancelled`, or the job is deleted                 | `cancelled`     |

A retry does not make a task fail. The task fails only when Oban stops retrying the job.

MCPO does not implement the MCP protocol. It includes an adapter for [ExMCP](https://hex.pm/packages/ex_mcp). The core API does not depend on an MCP library.

## Installation

```elixir
def deps do
  [
    {:mcpo, "~> 0.1"},
    # Optional, for the ExMCP adapter:
    {:ex_mcp, "~> 1.5"}
  ]
end
```

MCPO needs [Oban](https://hexdocs.pm/oban). Set up Oban first, then run:

```sh
mix mcpo.install
```

It creates a migration for the `mcpo_tasks` table and, with `ex_mcp`, an MCP server module. Then it prints the next steps. Options: `--repo MyApp.Repo`, `--server MyApp.MCPServer`, `--no-server`, and `--prefix private`.

### Manual setup

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

> **Note:** Oban marks the job `completed` first, and then MCPO saves the result from the Oban telemetry event. Between these two steps the task stays `working`. If the result is not saved within 5 seconds (for example, the node stopped), the task becomes `completed` with no result. Change the time with `config :mcpo, result_grace_period: 5_000`.
>
> A result that cannot be saved as JSON makes the task `failed`.
>
> When Oban deletes a job before MCPO sees its final state (for example, the Pruner removed it), the task becomes `cancelled`. Keep the Pruner `max_age` longer than the time clients take to read a result.
>
> Workers with Oban `unique:` options: a duplicate job is rejected with `{:error, :job_conflict}`. Two tasks never share one job. With Oban's default unique states, a job that has already completed within the unique period also counts as a duplicate.

## Use with ExMCP

List your workers. Each worker becomes a tool:

```elixir
defmodule MyApp.MCPServer do
  use MCPO.ExMCP,
    tools: [
      MyApp.Workers.GenerateReport,
      {MyApp.Workers.SendEmail,
       description: "Sends an email.",
       input_schema: %{
         "type" => "object",
         "properties" => %{"to" => %{"type" => "string"}},
         "required" => ["to"]
       }}
    ]
end
```

A worker can describe itself with `use MCPO.Tool`. The `@moduledoc` text becomes the tool description:

```elixir
defmodule MyApp.Workers.GenerateReport do
  @moduledoc """
  Generates a report in the background.
  """

  use Oban.Worker, queue: :reports

  use MCPO.Tool,
    input_schema: %{
      "type" => "object",
      "properties" => %{"steps" => %{"type" => "integer"}},
      "required" => ["steps"]
    }
end
```

`use MCPO.Tool` reads `@moduledoc` when the worker compiles. So the description is there also in a release, where `mix release` removes the docs from the compiled files.

Each value comes from the first place that has it:

1. The options in the `tools:` list
2. `use MCPO.Tool` options (`:name`, `:description`, `:input_schema`)
3. The worker's `@moduledoc` (description only, with `use MCPO.Tool`)
4. The `args_schema` of an Oban Pro worker (input schema only, see below)
5. The default:

| Option          | Default                                                        |
| --------------- | -------------------------------------------------------------- |
| `:name`         | From the module name: `MyApp.Workers.SendEmail` → `send_email` |
| `:description`  | `"Runs MyApp.Workers.SendEmail as a background job."`          |
| `:input_schema` | `%{"type" => "object"}` (any arguments)                        |

The tool arguments become the job args. MCPO checks them against the input schema first. Invalid arguments get back a tool result with `"isError": true` and a list of the problems, and no job starts. The AI model can then correct its call. An invalid input schema stops the build with an error.

### Oban Pro workers

An Oban Pro worker with `args_schema` needs no `input_schema`. MCPO builds it from the fields:

```elixir
defmodule MyApp.Workers.UpdateOffice do
  @moduledoc "Updates an office."
  use Oban.Pro.Worker
  use MCPO.Tool

  args_schema do
    field :id, :id, required: true
    field :mode, :enum, values: ~w(enabled disabled)a, default: :enabled

    embeds_one :data, required: true do
      field :office_id, :uuid, required: true
    end
  end

  @impl Oban.Pro.Worker
  def process(_job), do: :ok
end
```

| `args_schema`                                    | JSON Schema                                           |
| ------------------------------------------------ | ----------------------------------------------------- |
| `:id`, `:integer`                                | `integer`                                             |
| `:float`, `:decimal`                             | `number`                                              |
| `:string`, `:binary`                             | `string`                                              |
| `:boolean`                                       | `boolean`                                             |
| `:uuid`, `:binary_id`                            | `string`, format `uuid`                               |
| `:date`, `:time`, `:utc_datetime`, and similar   | `string`, format `date`, `time` or `date-time`        |
| `:map`                                           | `object`                                              |
| `:enum`                                          | `string` with `enum` values                           |
| `{:array, type}`                                 | `array` of `type`                                     |
| `embeds_one`, `embeds_many`                      | `object`, or `array` of `object`                      |
| `:term`                                          | any value                                             |

`required: true` and `default:` are kept. Unknown keys are not allowed, as in Oban Pro. MCPO does not depend on Oban Pro: it reads the schema from `__args_schema__/0`, which Oban Pro defines. This function is not documented by Oban Pro, so a future Pro version can change it. MCPO was checked with Oban Pro 1.5 to 1.7.10.

`use MCPO.ExMCP` is `use ExMCP.Server.Handler` with the MCPO task store. It defines `handle_initialize/2`, `handle_list_tools/2`, and `handle_call_tool/3`. Other handler options are passed on to ExMCP. Set `server_info: %{"name" => ..., "version" => ...}` to change the server name.

To add a tool that is not an Oban job, define `handle_call_tool/3` and call `super` for the other tools:

```elixir
def handle_call_tool("echo", %{"text" => text}, state),
  do: {:ok, %{"content" => [%{"type" => "text", "text" => text}]}, state}

def handle_call_tool(name, arguments, state), do: super(name, arguments, state)
```

Also define `handle_list_tools/2` and add your tool to the list from `super`. `create_task/4` starts a job from your own `handle_call_tool/3`.

ExMCP then answers `tasks/get` and `tasks/cancel` from the MCPO table:

- A completed task returns its result as a tool call result. The result map is in `structuredContent`, and as JSON text in `content`. If your result already has a `"content"` key, it is sent without change.
- A failed task returns a JSON-RPC error.
- Each task is bound to the ExMCP owner (principal, tenant, and audience). Other owners cannot read or cancel it.

### Clients without tasks

Many clients do not support the MCP Tasks extension yet. For example, the MCP Inspector uses the TypeScript SDK, and its latest protocol is `2025-11-25`. For these clients, MCPO waits for the Oban job and returns the tool result directly. The work still runs in Oban, with retries.

- A failed or cancelled job returns a tool result with `"isError": true`.
- If the job does not finish in `:wait_timeout` (9 seconds by default), MCPO cancels the task and returns an error result.
- While the call waits, it is blocked. Over HTTP, ExMCP stops a handler call after `:handler_call_timeout` (10 seconds by default). For longer jobs, raise both values:

  ```elixir
  use MCPO.ExMCP, task_store_opts: [wait_timeout: 60_000]

  # and on the plug:
  Plug.Cowboy.http(ExMCP.HttpPlug, [handler: MyApp.MCPServer, handler_call_timeout: 65_000], port: 4000)
  ```

- Over stdio, other requests on the same connection wait.

Listed tools have `"execution" => %{"taskSupport" => "optional"}`, so both kinds of client can call them. The generated `handle_initialize/2` returns the `tools` capability, so older clients ask for the tool list.

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

The Cleaner job goes to the `:default` queue. If your app does not run that queue, set a queue that it runs, for example `{"@hourly", MCPO.Cleaner, queue: :maintenance}`. Otherwise old tasks are never deleted.

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
