# Use with FastestMCP

Add `{:fastest_mcp, "~> 0.3.2"}` to your deps. Then add your workers as tools:

```elixir
server =
  FastestMCP.server("reports")
  |> MCPJobs.FastestMCP.add_tools([
    MyApp.Workers.GenerateReport,
    {MyApp.Workers.SendEmail, description: "Sends an email."}
  ])
```

The tool name, description and input schema follow the same rules as with ExMCP. FastestMCP checks the arguments against the input schema.

Each tool call inserts an Oban job and waits for it. FastestMCP decides how the client gets the result:

- A client with MCP Tasks gets a task at once. FastestMCP supports both task versions, `2025-11-25` and the `2026-07-28` extension, so clients with the current TypeScript SDK also get real tasks.
- A client without tasks waits for the result. If the job does not finish in `:wait_timeout` (9 seconds by default), MCPJobs cancels it and returns an error result. Over HTTP, FastestMCP stops a request after `stream_request_timeout_ms` (60 seconds by default). For a longer wait, raise both:

  ```elixir
  MCPJobs.FastestMCP.add_tools(server, tools, wait_timeout: 300_000)

  FastestMCP.streamable_http_child_spec("reports", port: 4001, stream_request_timeout_ms: 305_000)
  ```
- A failed or cancelled job returns a tool result with `isError: true`.

When a client cancels a FastestMCP task (`tasks/cancel`), FastestMCP stops the waiting tool process. MCPJobs then cancels the MCPJobs task and its job. When the tool process stops for another reason (the server stops, the client disconnects, or the wait fails), the job keeps running and the MCPJobs task finishes as usual.

Options of `add_tools/3`: `:oban`, `:job`, `:kill`, `:wait_timeout`, `:interval` (the time between two status checks: 1000 ms for tasks, 100 ms without tasks), and `:task` (the FastestMCP task option, default `[mode: :optional]`).

## Durable FastestMCP tasks

FastestMCP keeps its tasks in memory by default, so a restart loses them. Use the MCPJobs task backend to keep them in PostgreSQL:

```elixir
FastestMCP.start_server(server, task_backend: {MCPJobs.FastestMCP.TaskBackend, oban: Oban})
```

After a restart, FastestMCP marks unfinished tasks as failed. For a task of an MCPJobs tool, the Oban job is not gone, so the backend keeps the task working and shows the state of the MCPJobs task: its progress while it works, then its result, its error, or `cancelled`. A client can also cancel such a task, and MCPJobs then cancels the job. Options: `:oban`, and `:kill` (a cancel after a restart also kills a running job).

The backend uses the `mcp_jobs_fastest_tasks` table, which `MCPJobs.Migration` creates.
