port = String.to_integer(System.get_env("PORT", "4001"))

{:ok, _pid} =
  "report-server"
  |> FastestMCP.server()
  |> MCPO.FastestMCP.add_tools([ReportServer.Workers.GenerateReport])
  |> FastestMCP.start_server()

{:ok, _pid} =
  Supervisor.start_link(
    [
      FastestMCP.streamable_http_child_spec("report-server",
        port: port,
        allowed_hosts: :localhost
      )
    ],
    strategy: :one_for_one
  )

IO.puts("MCP server (FastestMCP): http://localhost:#{port}/mcp")

# The HTTP supervisor is linked to this script process, so keep the process alive.
Process.sleep(:infinity)
