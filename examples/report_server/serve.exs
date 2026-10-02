port = String.to_integer(System.get_env("PORT", "4000"))

origins =
  for host <- ["localhost", "127.0.0.1"], origin_port <- [port, 6274],
      do: "http://#{host}:#{origin_port}"

{:ok, _pid} =
  Plug.Cowboy.http(
    ExMCP.HttpPlug,
    [
      handler: ReportServer.MCPServer,
      protocol_mode: :prefer_modern,
      allowed_origins: origins
    ],
    port: port
  )

IO.puts("MCP server: http://localhost:#{port}/")
