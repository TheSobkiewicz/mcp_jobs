defmodule ReportServer.MCPServer do
  @moduledoc """
  An MCP server with one long running tool. Each call runs as an Oban job.

  Clients with the MCP Tasks extension get a task at once. Other clients wait
  for the result.
  """

  use MCPO.ExMCP

  @legacy_versions ~w(2025-11-25 2025-06-18 2025-03-26 2024-11-05)

  @impl ExMCP.Server.Handler
  def handle_initialize(%{"protocolVersion" => version}, state) do
    version = if version in @legacy_versions, do: version, else: hd(@legacy_versions)

    {:ok,
     %{
       "protocolVersion" => version,
       "serverInfo" => %{"name" => "report-server", "version" => "0.1.0"},
       "capabilities" => %{"tools" => %{}}
     }, state}
  end

  @impl ExMCP.Server.Handler
  def handle_list_tools(_cursor, state) do
    tool = %{
      "name" => "generate_report",
      "description" => "Generates a report in the background.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"steps" => %{"type" => "integer", "minimum" => 1}},
        "required" => ["steps"]
      },
      "execution" => %{"taskSupport" => "optional"}
    }

    {:ok, [tool], nil, state}
  end

  @impl ExMCP.Server.Handler
  def handle_call_tool("generate_report", arguments, state) do
    create_task("generate_report", ReportServer.Workers.GenerateReport, arguments, state)
  end
end
