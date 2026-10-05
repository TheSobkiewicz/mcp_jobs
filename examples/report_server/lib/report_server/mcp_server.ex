defmodule ReportServer.MCPServer do
  @moduledoc """
  An MCP server with one long running tool. Each call runs as an Oban job.
  """

  use MCPOban.ExMCP,
    server_info: %{"name" => "report-server", "version" => "0.1.0"},
    tools: [ReportServer.Workers.GenerateReport]
end
