# MCPOban

Runs MCP tool calls as [Oban](https://hex.pm/packages/oban) jobs.

An MCP client calls a tool. The server gives back a task ID at once, and Oban does the work in the background. The client asks for the task status until the task is done. The MCP task status follows the Oban job state:

| Oban job state                                     | MCP task status |
| -------------------------------------------------- | --------------- |
| `available`, `scheduled`, `executing`, `retryable`, `suspended` | `working` |
| `completed`                                        | `completed`     |
| `discarded` (all attempts failed)                  | `failed`        |
| `cancelled`, or the job is deleted                 | `cancelled`     |

A retry does not make a task fail. The task fails only when Oban stops retrying the job.

MCPOban does not implement the MCP protocol. It includes an adapter for [ExMCP](https://hex.pm/packages/ex_mcp). The core API does not depend on an MCP library.

## Installation

```elixir
def deps do
  [
    {:mcp_oban, "~> 0.1"},
    # Optional, for the ExMCP adapter:
    {:ex_mcp, "~> 1.5"}
  ]
end
```

MCPOban needs [Oban](https://hexdocs.pm/oban) with PostgreSQL. It does not work with the MySQL or SQLite engines of Oban. Set up Oban first, then run:

```sh
mix mcp_oban.install
```

It creates a migration for the `mcp_oban_tasks` table and, with `ex_mcp`, an MCP server module. Then it prints the next steps. Options: `--repo MyApp.Repo`, `--server MyApp.MCPServer`, `--no-server`, and `--prefix private`.

### Manual setup

MCPOban uses the repo of your Oban instance. Add a migration:

```elixir
defmodule MyApp.Repo.Migrations.AddMCPObanTasks do
  use Ecto.Migration

  def up, do: MCPOban.Migration.up()
  def down, do: MCPOban.Migration.down()
end
```

If Oban uses a prefix, pass the same prefix: `MCPOban.Migration.up(prefix: "private")`.

### Upgrading

The `mcp_oban_tasks` table has a version, stored as a comment on the table. When a new MCPOban release changes the table, add a migration that runs only the missing versions:

```elixir
defmodule MyApp.Repo.Migrations.UpgradeMCPObanTasks do
  use Ecto.Migration

  def up, do: MCPOban.Migration.up(version: 2)
  def down, do: MCPOban.Migration.down(version: 2)
end
```

Version 2 added the `progress` column. `MCPOban.Migration.migrated_version/1` returns the version of your database.

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

The result is stored as JSON, so atom keys come back as strings. The result must be JSON-safe: for example, no tuples or PIDs. A struct such as `DateTime` is saved as `%{"value" => ...}`.

> **Note:** Oban marks the job `completed` first, and then MCPOban saves the result from the Oban telemetry event. Between these two steps the task stays `working`. If the result is not saved within 5 seconds (for example, the node stopped), the task becomes `completed` with no result. Change the time with `config :mcp_oban, result_grace_period: 5_000`.
>
> A result that cannot be saved as JSON makes the task `failed`.
>
> When Oban deletes a job before MCPOban sees its final state (for example, the Pruner removed it), the task becomes `cancelled`. Keep the Pruner `max_age` longer than the time clients take to read a result.
>
> Workers with Oban `unique:` options: a duplicate job is rejected with `{:error, :job_conflict}`. Two tasks never share one job. With Oban's default unique states, a job that has already completed within the unique period also counts as a duplicate.

## Use with ExMCP

List your workers. Each worker becomes a tool:

```elixir
defmodule MyApp.MCPServer do
  use MCPOban.ExMCP,
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

A worker can describe itself with `use MCPOban.Tool`. The `@moduledoc` text becomes the tool description:

```elixir
defmodule MyApp.Workers.GenerateReport do
  @moduledoc """
  Generates a report in the background.
  """

  use Oban.Worker, queue: :reports

  use MCPOban.Tool,
    input_schema: %{
      "type" => "object",
      "properties" => %{"steps" => %{"type" => "integer"}},
      "required" => ["steps"]
    }
end
```

`use MCPOban.Tool` reads `@moduledoc` when the worker compiles. So the description is there also in a release, where `mix release` removes the docs from the compiled files.

Each value comes from the first place that has it:

1. The options in the `tools:` list
2. `use MCPOban.Tool` options (`:name`, `:description`, `:input_schema`)
3. The worker's `@moduledoc` (description only, with `use MCPOban.Tool`)
4. The `args_schema` of an Oban Pro worker (input schema only, see below)
5. The default:

| Option          | Default                                                        |
| --------------- | -------------------------------------------------------------- |
| `:name`         | From the module name: `MyApp.Workers.SendEmail` → `send_email` |
| `:description`  | `"Runs MyApp.Workers.SendEmail as a background job."`          |
| `:input_schema` | `%{"type" => "object"}` (any arguments)                        |

The tool arguments become the job args. MCPOban checks them against the input schema first. Invalid arguments get back a tool result with `"isError": true` and a list of the problems, and no job starts. The AI model can then correct its call. An invalid input schema stops the build with an error.

### Oban Pro workers

An Oban Pro worker with `args_schema` needs no `input_schema`. MCPOban builds it from the fields:

```elixir
defmodule MyApp.Workers.UpdateOffice do
  @moduledoc "Updates an office."
  use Oban.Pro.Worker
  use MCPOban.Tool

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

`required: true` and `default:` are kept. Unknown keys are not allowed, as in Oban Pro. MCPOban does not depend on Oban Pro: it reads the schema from `__args_schema__/0`, which Oban Pro defines. This function is not documented by Oban Pro, so a future Pro version can change it. MCPOban was checked with Oban Pro 1.5 to 1.7.10.

`use MCPOban.ExMCP` is `use ExMCP.Server.Handler` with the MCPOban task store. It defines `handle_initialize/2`, `handle_list_tools/2`, and `handle_call_tool/3`. Other handler options are passed on to ExMCP. Set `server_info: %{"name" => ..., "version" => ...}` to change the server name.

To add a tool that is not an Oban job, define `handle_call_tool/3` and call `super` for the other tools:

```elixir
def handle_call_tool("echo", %{"text" => text}, state),
  do: {:ok, %{"content" => [%{"type" => "text", "text" => text}]}, state}

def handle_call_tool(name, arguments, state), do: super(name, arguments, state)
```

Also define `handle_list_tools/2` and add your tool to the list from `super`. `create_task/4` starts a job from your own `handle_call_tool/3`.

ExMCP then answers `tasks/get` and `tasks/cancel` from the MCPOban table:

- A completed task returns its result as a tool call result. The result map is in `structuredContent`, and as JSON text in `content`. If your result already has a `"content"` list of content blocks, it is sent without change.
- A failed task returns a JSON-RPC error with only the safe error message (see [Errors](#errors)).
- Each task is bound to the ExMCP owner (principal, tenant, and audience). Other owners cannot read or cancel it.

### Clients without tasks

Many clients do not support the MCP Tasks extension yet. For example, the MCP Inspector uses the TypeScript SDK, and its latest protocol is `2025-11-25`. For these clients, MCPOban waits for the Oban job and returns the tool result directly. The work still runs in Oban, with retries.

- A failed or cancelled job returns a tool result with `"isError": true`.
- If the job does not finish in `:wait_timeout` (9 seconds by default), MCPOban cancels the task and returns an error result.
- While the call waits, it is blocked. Over HTTP, ExMCP stops a handler call after `:handler_call_timeout` (10 seconds by default). For longer jobs, raise both values:

  ```elixir
  use MCPOban.ExMCP, task_store_opts: [wait_timeout: 60_000, interval: 500]

  # and on the plug:
  Plug.Cowboy.http(ExMCP.HttpPlug, [handler: MyApp.MCPServer, handler_call_timeout: 65_000], port: 4000)
  ```

- Over stdio, other requests on the same connection wait.

Listed tools have `"execution" => %{"taskSupport" => "optional"}`, so both kinds of client can call them. The generated `handle_initialize/2` returns the `tools` capability, so older clients ask for the tool list.

### Limits

- MCPOban supports the MCP Tasks extension (spec 2026-07-28). Older clients get the direct result described above, not a task.
- The `input_required` status is not supported.
- MCPOban does not send `notifications/tasks`, so clients must poll with `tasks/get`.

## Use with FastestMCP

Add `{:fastest_mcp, "~> 0.3.2"}` to your deps. Then add your workers as tools:

```elixir
server =
  FastestMCP.server("reports")
  |> MCPOban.FastestMCP.add_tools([
    MyApp.Workers.GenerateReport,
    {MyApp.Workers.SendEmail, description: "Sends an email."}
  ])
```

The tool name, description and input schema follow the same rules as with ExMCP. FastestMCP checks the arguments against the input schema.

Each tool call inserts an Oban job and waits for it. FastestMCP decides how the client gets the result:

- A client with MCP Tasks gets a task at once. FastestMCP supports both task versions, `2025-11-25` and the `2026-07-28` extension, so clients with the current TypeScript SDK also get real tasks.
- A client without tasks waits for the result. If the job does not finish in `:wait_timeout` (9 seconds by default), MCPOban cancels it and returns an error result.
- A failed or cancelled job returns a tool result with `isError: true`.

When a client cancels a FastestMCP task (`tasks/cancel`), FastestMCP stops the waiting tool process. MCPOban then cancels the MCPOban task and its job. When the tool process stops for another reason (the server stops, the client disconnects, or the wait fails), the job keeps running and the MCPOban task finishes as usual.

Options of `add_tools/3`: `:oban`, `:job`, `:kill`, `:wait_timeout`, `:interval` (the time between two status checks: 1000 ms for tasks, 100 ms without tasks), and `:task` (the FastestMCP task option, default `[mode: :optional]`).

Limit: FastestMCP keeps its tasks in memory by default. After a restart, clients cannot read FastestMCP tasks from before the restart, even though the Oban job and the MCPOban task still exist.

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

To make an adapter for a different MCP server, use `MCPOban.enqueue/3`, `MCPOban.get/2`, and `MCPOban.cancel/2`. For clients that cannot poll, `MCPOban.await/2` waits until the task is done.

### Duplicate requests

Give the MCP task ID as `task_id:`. If a task with this ID already exists for the same worker and owner, `enqueue/3` returns it and does not insert a second job. If the worker or the owner is different, it returns `{:error, :already_exists}`, so one owner never gets another owner's task. A unique index in the database enforces this, also for requests that arrive at the same time.

## Progress

A long worker can report its progress:

```elixir
def perform(%Oban.Job{args: %{"steps" => steps}} = job) do
  for step <- 1..steps do
    do_step(step)
    MCPOban.progress(job, step, steps, "Wrote section #{step}")
  end

  {:ok, %{"sections" => steps}}
end
```

`MCPOban.progress(job, current, total \\ nil, message \\ nil)` saves the progress while the task is `working`. `current` should grow. Clients see it:

- With ExMCP, `tasks/get` shows it as `statusMessage`, for example `"Wrote section 2 (2/5)"`. A client without tasks gets progress notifications when it sent a progress token.
- With FastestMCP, it becomes the progress of the FastestMCP task, and FastestMCP sends it to the client.
- `MCPOban.status/2` returns it as `%{status: :working, progress: %{"current" => 2, "total" => 5, "message" => "..."}}`.

The adapters check for new progress at their `:interval`.

## Errors

When a job fails for good, the task error is:

```elixir
%{"message" => "The task failed.", "details" => "...the exception or the returned reason..."}
```

MCP clients get only `"message"`. The `"details"` can hold internal data (secrets, database values, stack traces), so they stay on the server: in `MCPOban.status/2` and in the `mcp_oban_tasks` table.

To choose the message that clients see, return it from `perform/1`:

```elixir
{:error, %{"message" => "The report period is empty."}}
```

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

  If the worker does not stop, it runs to the end, but its result is not saved. The task stays `cancelled`. If the attempt fails or snoozes, MCPOban cancels the job, so Oban does not run it again.

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

The Cleaner job goes to the `:default` queue. If your app does not run that queue, set a queue that it runs, for example `{"@hourly", MCPOban.Cleaner, queue: :maintenance}`. Otherwise old tasks are never deleted.

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

The same worker with FastestMCP runs on port 4001: `mix run serve_fastest.exs`, then use `http://localhost:4001/mcp`.

## Development

Tests need a local Postgres.

```sh
mix test
```
