port = String.to_integer(System.get_env("PORT", "4001"))

{:ok, _pid} =
  "deep-thought"
  |> FastestMCP.server()
  |> MCPJobs.FastestMCP.add_tools([DeepThought.Workers.AnswerUltimateQuestion], wait_timeout: 300_000)
  |> FastestMCP.start_server(task_backend: {MCPJobs.FastestMCP.TaskBackend, oban: Oban})

{:ok, _pid} =
  Supervisor.start_link(
    [
      FastestMCP.streamable_http_child_spec("deep-thought",
        port: port,
        allowed_hosts: :localhost,
        stream_request_timeout_ms: 305_000
      )
    ],
    strategy: :one_for_one
  )

IO.puts("MCP server (FastestMCP): http://localhost:#{port}/mcp")

# The HTTP supervisor is linked to this script process, so keep the process alive.
Process.sleep(:infinity)
