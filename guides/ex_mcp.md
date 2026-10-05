# Use with ExMCP

List your workers. Each worker becomes a tool:

```elixir
defmodule MyApp.MCPServer do
  use MCPJobs.ExMCP,
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

A worker can describe itself with `use MCPJobs.Tool`. The `@moduledoc` text becomes the tool description:

```elixir
defmodule MyApp.Workers.GenerateReport do
  @moduledoc """
  Generates a report in the background.
  """

  use Oban.Worker, queue: :reports

  use MCPJobs.Tool,
    input_schema: %{
      "type" => "object",
      "properties" => %{"steps" => %{"type" => "integer"}},
      "required" => ["steps"]
    }
end
```

`use MCPJobs.Tool` reads `@moduledoc` when the worker compiles. So the description is there also in a release, where `mix release` removes the docs from the compiled files.

Each value comes from the first place that has it:

1. The options in the `tools:` list
2. `use MCPJobs.Tool` options (`:name`, `:description`, `:input_schema`)
3. The worker's `@moduledoc` (description only, with `use MCPJobs.Tool`)
4. The `args_schema` of an Oban Pro worker (input schema only, see below)
5. The default:

| Option          | Default                                                        |
| --------------- | -------------------------------------------------------------- |
| `:name`         | From the module name: `MyApp.Workers.SendEmail` → `send_email` |
| `:description`  | `"Runs MyApp.Workers.SendEmail as a background job."`          |
| `:input_schema` | `%{"type" => "object"}` (any arguments)                        |

The tool arguments become the job args. MCPJobs checks them against the input schema first. Invalid arguments get back a tool result with `"isError": true` and a list of the problems, and no job starts. The AI model can then correct its call. An invalid input schema stops the build with an error.

## Oban Pro workers

An Oban Pro worker with `args_schema` needs no `input_schema`. MCPJobs builds it from the fields:

```elixir
defmodule MyApp.Workers.UpdateOffice do
  @moduledoc "Updates an office."
  use Oban.Pro.Worker
  use MCPJobs.Tool

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

`required: true` and `default:` are kept. Unknown keys are not allowed, as in Oban Pro. MCPJobs does not depend on Oban Pro: it reads the schema from `__args_schema__/0`, which Oban Pro defines. This function is not documented by Oban Pro, so a future Pro version can change it. The tests use a worker with the same `__args_schema__/0` format.

`use MCPJobs.ExMCP` is `use ExMCP.Server.Handler` with the MCPJobs task store. It defines `handle_initialize/2`, `handle_list_tools/2`, and `handle_call_tool/3`. Other handler options are passed on to ExMCP. Set `server_info: %{"name" => ..., "version" => ...}` to change the server name.

To add a tool that is not an Oban job, define `handle_call_tool/3` and call `super` for the other tools:

```elixir
def handle_call_tool("echo", %{"text" => text}, state),
  do: {:ok, %{"content" => [%{"type" => "text", "text" => text}]}, state}

def handle_call_tool(name, arguments, state), do: super(name, arguments, state)
```

Also define `handle_list_tools/2` and add your tool to the list from `super`. `create_task/4` starts a job from your own `handle_call_tool/3`.

ExMCP then answers `tasks/get` and `tasks/cancel` from the MCPJobs table:

- A completed task returns its result as a tool call result. The result map is in `structuredContent`, and as JSON text in `content`. If your result already has a `"content"` list of content blocks, it is sent without change.
- A failed task returns a JSON-RPC error with only the safe error message (see [Errors](workers.md#errors)).
- Each task is bound to the ExMCP owner (principal, tenant, and audience). Other owners cannot read or cancel it.

## Clients without tasks

Many clients do not support the MCP Tasks extension yet. For example, the MCP Inspector uses the TypeScript SDK, and its latest protocol is `2025-11-25`. For these clients, MCPJobs waits for the Oban job and returns the tool result directly. The work still runs in Oban, with retries.

- A failed or cancelled job returns a tool result with `"isError": true`.
- If the job does not finish in `:wait_timeout`, MCPJobs cancels the task and returns an error result.
- Over stdio, other requests on the same connection wait.

### Time limits

The default `:wait_timeout` is only 9 seconds, because every part of the HTTP chain has its own limit, and a wait that is longer than one of them breaks the call. For longer jobs, raise all of them. Each limit must be longer than the one before it:

| Limit | Default | Where |
| --- | --- | --- |
| `:wait_timeout` | 9 seconds | `use MCPJobs.ExMCP, task_store_opts: [wait_timeout: ...]` |
| `:handler_call_timeout` | 10 seconds | the `ExMCP.HttpPlug` options |
| `idle_timeout` | 60 seconds | Cowboy only: `protocol_options: [idle_timeout: ...]` |

For example, for 5 minutes:

```elixir
use MCPJobs.ExMCP, task_store_opts: [wait_timeout: 300_000], tools: [...]

Plug.Cowboy.http(
  ExMCP.HttpPlug,
  [handler: MyApp.MCPServer, handler_call_timeout: 305_000],
  port: 4000,
  protocol_options: [idle_timeout: 310_000]
)
```

`mix mcp_jobs.install` sets these values. Bandit, the default web server of Phoenix, does not stop a request while it runs. A proxy in front of your app can also have a limit, for example `proxy_read_timeout` in nginx (60 seconds by default). The client can have a limit too.

Listed tools have `"execution" => %{"taskSupport" => "optional"}`, so both kinds of client can call them. The generated `handle_initialize/2` returns the `tools` capability, so older clients ask for the tool list.

## Limits

- MCPJobs supports the MCP Tasks extension (spec 2026-07-28). Older clients get the direct result described above, not a task.
- The `input_required` status is not supported.

## Task notifications

A client can listen for task changes (`subscriptions/listen` with a `"taskIds"` filter) instead of polling with `tasks/get`. MCPJobs then sends `notifications/tasks` when the job completes or fails, when the task is cancelled, and when the worker reports progress.

ExMCP keeps listeners on the local node. In a cluster, a client gets notifications only for jobs that finish on the node of its connection, unless you configure an ExMCP subscription adapter for the cluster. If you start your own `ExMCP.Server.Subscriptions` registry, set `config :mcp_jobs, ex_mcp_subscription_registry: MyApp.Registry`.
