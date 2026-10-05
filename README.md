# MCPJobs

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

MCPJobs is a small Elixir library that runs MCP tool calls as [Oban](https://hex.pm/packages/oban) jobs.

An MCP tool call usually blocks until the tool is done. This is a problem for slow work, such as reports, exports, file processing, slow external APIs, data imports, or bulk emails. The client waits, the connection can time out, and a restart loses the work.

With MCPJobs, the tool call gives back an MCP task at once, and Oban does the work in the background.

## Features

**No timeouts, no lost work**

- The tool call returns a task ID at once. A 10-minute job does not keep a request open.
- The work runs as an Oban job, with Oban queues, retries, and backoff.
- Tasks are stored in PostgreSQL, so they survive restarts and deploys. Every node can read them.

**A task status you can trust**

- **A retry does not fail the task.** The task fails only when Oban discards the job.
- **No races.** Each status change is one conditional database update, so the first change wins. A task that completes while a client cancels it is never both.
- **Self-repair.** If a node stops before MCPJobs saves the final state, the next read fixes the task from the Oban job.

**Tools for long workers**

- **Progress:** `MCPJobs.progress(job, 2, 5, "Rendering")` reaches the client as a status message and as notifications. The value never goes down, also after a retry.
- **Cancellation:** a waiting job is cancelled in Oban. A running worker checks `MCPJobs.cancelled?(job)` and stops cleanly.
- **Safe errors:** the client gets only the error message. The details stay on the server.

**Easy to adopt**

- **Plain Oban workers.** They do not need to know about MCP. The `perform/1` return value becomes the task result. Oban Web still shows every job.
- **Tool list from your code.** The `@moduledoc` becomes the tool description. The input schema comes from the tool options or from an Oban Pro args schema. Oban Pro is not required.
- **Works with older clients.** A client without MCP Tasks gets the result directly. The work still runs in Oban.
- **Small.** It does not implement the MCP protocol. It plugs into [ExMCP](https://hex.pm/packages/ex_mcp) or [FastestMCP](https://hex.pm/packages/fastest_mcp), and the core API works without an MCP library. It starts no processes and has no repo config of its own.

## Usage

Write a plain Oban worker. The `@moduledoc` becomes the tool description, and the input schema tells the AI client which arguments to send:

```elixir
defmodule MyApp.Workers.GenerateReport do
  @moduledoc "Generates a report in the background."

  use Oban.Worker, queue: :reports, max_attempts: 3

  use MCPJobs.Tool,
    input_schema: %{
      "type" => "object",
      "properties" => %{"report_id" => %{"type" => "integer"}},
      "required" => ["report_id"]
    }

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

`mix mcp_jobs.install` prints how to serve it over HTTP. The client calls `generate_report` and gets a task ID at once. It then reads the task with `tasks/get`, or listens for `notifications/tasks`, until the task is done:

```json
{"taskId": "...", "status": "working", "statusMessage": "Loading data (1/2)"}
{"taskId": "...", "status": "completed", "result": {"structuredContent": {"url": "..."}}}
```

The MCP task status follows the Oban job state:

| Oban job state                                                  | MCP task status |
| --------------------------------------------------------------- | --------------- |
| `available`, `scheduled`, `executing`, `retryable`, `suspended` | `working`       |
| `completed`                                                     | `completed`     |
| `discarded` (all attempts failed)                               | `failed`        |
| `cancelled`, or the job is deleted                              | `cancelled`     |

## Installation

MCPJobs needs Oban with PostgreSQL. It is not on Hex yet, so install it from GitHub.

```elixir
def deps do
  [
    {:mcp_jobs, github: "TheSobkiewicz/mcp_jobs"},
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

`examples/deep_thought` is a small app with one tool, `answer_ultimate_question`. It takes 7.5 million years (about 3 seconds). Its demo shows all features:

- **Progress and push notifications:** "Thinking. 3 million years have passed (3/6)"
- **Retry:** on the first attempt a mouse interrupts the calculation. Oban retries the job, and the task stays `working`.
- **Cancel:** the Vogons demolish the Earth during the calculation.
- **Safe errors:** Deep Thought cannot compute the Ultimate Question itself. The client gets only the message, and the details stay on the server.

```sh
cd examples/deep_thought
mix deps.get
mix ecto.create && mix ecto.migrate
mix run demo.exs
```

Stop `serve.exs` and `serve_fastest.exs` before you run the demo. They use the same queue, so they can take its jobs.

To use it from another MCP client, start it over HTTP on port 4000:

```sh
mix run --no-halt serve.exs
npx @modelcontextprotocol/inspector --cli http://localhost:4000/ --transport http \
  --method tools/call --tool-name answer_ultimate_question
```

The same worker with FastestMCP runs on port 4001: `mix run serve_fastest.exs`, then use `http://localhost:4001/mcp`.

## Development

Tests need a local Postgres.

```sh
mix test
```

## License

MIT. See [LICENSE](LICENSE).
