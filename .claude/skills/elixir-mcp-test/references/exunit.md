# ExUnit tests for Elixir MCP servers

Use these patterns to keep a live check as a test. Copy the style of the project's existing tests first: their case template, helpers and tags.

## Contents

1. ExMCP, in-process (BEAM transport)
2. ExMCP over real HTTP
3. FastestMCP
4. Oban jobs in tests
5. What to test

## 1. ExMCP, in-process (BEAM transport)

Fast, and no port. Good for the task logic.

```elixir
alias ExMCP.Tasks.Extension

setup do
  {:ok, server} =
    ExMCP.Server.HandlerServer.start_link(
      handler: MyApp.MCPServer,
      transport: :beam,
      protocol_mode: :prefer_modern
    )

  {:ok, client} =
    ExMCP.Client.start_link(
      transport: :beam,
      server: server,
      protocol_mode: :prefer_modern,
      # Without this the client has no tasks, and the call waits for the result.
      capabilities: Extension.put_capability(%{})
    )

  %{client: client}
end

test "a tool call returns a task", %{client: client} do
  {:ok, %{"resultType" => "task", "taskId" => task_id, "status" => "working"}} =
    ExMCP.Client.call_tool(client, "generate_report", %{"value" => 5}, format: :map)

  drain()

  assert {:ok, %{"status" => "completed", "result" => %{"structuredContent" => %{"value" => 5}}}} =
           ExMCP.Client.get_task(client, task_id)
end
```

Other client calls: `ExMCP.Client.cancel_task/2`, `ExMCP.Client.list_tools(client, format: :map)`, and `ExMCP.Client.listen(client, %{"taskIds" => [id]})`. After `listen`, use `assert_receive {:ex_mcp_subscription, _ref, "notifications/tasks", %{"status" => ...}}`.

## 2. ExMCP over real HTTP

Use this for headers, origins and protocol versions. Port `0` picks a free port.

```elixir
setup do
  ref = make_ref()

  {:ok, _pid} =
    Plug.Cowboy.http(
      ExMCP.HttpPlug,
      [handler: MyApp.MCPServer, protocol_mode: :prefer_modern, allowed_origins: :any,
       server_info: MyApp.MCPServer.server_info()],
      port: 0,
      ref: ref
    )

  on_exit(fn -> Plug.Cowboy.shutdown(ref) end)

  {:ok, client} =
    ExMCP.Client.start_link(
      transport: :http,
      url: "http://localhost:#{:ranch.get_port(ref)}/",
      protocol_mode: :prefer_modern
    )

  %{client: client}
end
```

The HTTP server runs requests in other processes. With the Ecto SQL sandbox, these processes cannot see the test connection. Use shared sandbox mode (`async: false`), or the project's tag for tests without a sandbox (in MCPJobs: `@tag :unsandboxed`).

## 3. FastestMCP

FastestMCP has an in-process API by server name. No transport is necessary.

```elixir
setup do
  name = "test-#{System.unique_integer([:positive])}"

  {:ok, _pid} =
    name
    |> FastestMCP.server()
    |> MCPJobs.FastestMCP.add_tools([MyApp.Workers.GenerateReport], wait_timeout: 300, interval: 20)
    |> FastestMCP.start_server()

  on_exit(fn -> FastestMCP.stop_server(name) end)
  %{name: name}
end

test "a call without a task waits for the job", %{name: name} do
  stop_jobs = run_jobs_in_background()
  assert %{structuredContent: %{"value" => 4}} = FastestMCP.call_tool(name, "generate_report", %{"value" => 4})
  stop_jobs.()
end

test "a task call", %{name: name} do
  %FastestMCP.BackgroundTask{task_id: task_id} =
    FastestMCP.call_tool(name, "generate_report", %{"value" => 7}, task: true)
  # ...
end
```

`FastestMCP.list_tools(name)` returns the tools with atom keys (`:name`, `:description`, `:input_schema`, `:execution`).

## 4. Oban jobs in tests

With `Oban.start_link(repo: Repo, testing: :manual)`, jobs do not run by themselves.

- Run all jobs, with retries: `Oban.drain_queue(queue: :default, with_scheduled: true, with_recursion: true)`.
- A call that waits for its job (a client without tasks, or FastestMCP) blocks the test process. Run jobs in another process while it waits. MCPJobs has `run_jobs_in_background/0` in `test/support/data_case.ex`.
- For a state that changes later, poll with a timeout instead of `Process.sleep` (MCPJobs: `eventually/2`).

## 5. What to test

For each tool: one valid call, one invalid call (no job starts), and the result shape (`structuredContent` and `content`). For task support: `completed`, `failed` (only after the last attempt), `cancelled` (the Oban job is cancelled too), a retry that keeps the task `working`, an unknown task id, and a client without tasks. For ExMCP, also test that a different owner cannot read or cancel the task.
