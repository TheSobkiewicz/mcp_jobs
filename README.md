# MCPJobs

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

MCPJobs is a small Elixir library that runs MCP tool calls as [Oban](https://hex.pm/packages/oban) jobs.

An MCP tool call usually blocks until the tool is done. This is a problem for slow work: the client waits, the connection can time out, and a restart loses the work.

For example, a tool can:

- Generate a report or an export
- Process an uploaded file
- Call a slow external API
- Import or sync data
- Send many emails

---

With MCPJobs, the tool call gives back an MCP task at once, and Oban does the work in the background, with retries. The MCP task status follows the Oban job state, so a retry does not make the task fail:

| Oban job state                                                  | MCP task status |
| --------------------------------------------------------------- | --------------- |
| `available`, `scheduled`, `executing`, `retryable`, `suspended` | `working`       |
| `completed`                                                     | `completed`     |
| `discarded` (all attempts failed)                               | `failed`        |
| `cancelled`, or the job is deleted                              | `cancelled`     |

## Usage

Write a plain Oban worker. The `@moduledoc` becomes the tool description:

```elixir
defmodule MyApp.Workers.GenerateReport do
  @moduledoc "Generates a report in the background."

  use Oban.Worker, queue: :reports, max_attempts: 3
  use MCPJobs.Tool

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"report_id" => report_id}} = job) do
    MCPJobs.progress(job, 1, 2, "Loading data")

    {:ok, %{"url" => MyApp.Reports.generate(report_id)}}
  end
end
```

List your workers in the MCP server. Each worker becomes a tool:

```elixir
defmodule MyApp.MCPServer do
  use MCPJobs.ExMCP, tools: [MyApp.Workers.GenerateReport]
end
```

The client calls `generate_report` and gets a task ID at once. It then reads the task with `tasks/get`, or listens for `notifications/tasks`, until the task is done:

```json
{"taskId": "...", "status": "working", "statusMessage": "Loading data (1/2)"}
{"taskId": "...", "status": "completed", "result": {"structuredContent": {"url": "..."}}}
```

## Why MCPJobs?

- **Your workers stay plain Oban workers.** They do not need to know about MCP. You keep Oban queues, retries, uniqueness, and the Oban Web dashboard.
- **No lost work.** Tasks are stored in PostgreSQL, so they survive a restart, and every node can read them.
- **Safe state changes.** Each status change is one conditional database update, so the first change wins. A task that completes while a client cancels it is never both.
- **Works with older clients.** A client without MCP Tasks gets the result directly. The work still runs in Oban.
- **Small.** It does not implement the MCP protocol. It plugs into [ExMCP](https://hex.pm/packages/ex_mcp) or [FastestMCP](https://hex.pm/packages/fastest_mcp), and the core API works without an MCP library.

## Installation

MCPJobs needs Oban with PostgreSQL.

```elixir
def deps do
  [
    {:mcp_jobs, "~> 0.1"},
    # Optional, for the ExMCP adapter:
    {:ex_mcp, "~> 1.5"}
  ]
end
```

Set up Oban first, then run:

```sh
mix mcp_jobs.install
```

It creates the migration and an MCP server module, and prints the next steps. In a Phoenix app, add `--phoenix` to also add the `/mcp` route.

## Guides

- [Installation](guides/installation.md): installer options, manual setup, and Phoenix
- [Workers](guides/workers.md): results, progress, errors, cancellation
- [Use with ExMCP](guides/ex_mcp.md): tools, Oban Pro schemas, clients without tasks, notifications
- [Use with FastestMCP](guides/fastest_mcp.md): tools and durable tasks
- [Core API, telemetry and cleanup](guides/operations.md)

## Example

`examples/report_server` is a small app with one tool. Its demo calls the tool, waits for the result, and cancels a running job:

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

## License

MIT. See [LICENSE](LICENSE).
