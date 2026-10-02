defmodule ReportServer.MCPServer do
  @moduledoc """
  An MCP server with one long running tool. Each call runs as an Oban job.
  """

  use ExMCP.Server.Handler, tasks: :store, task_store: MCPOban.ExMCP.Store

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
      "execution" => %{"taskSupport" => "required"}
    }

    {:ok, [tool], nil, state}
  end

  @impl ExMCP.Server.Handler
  def handle_call_tool("generate_report", arguments, state) do
    MCPOban.ExMCP.create_task(
      "generate_report",
      ReportServer.Workers.GenerateReport,
      arguments,
      state,
      __task_store_options__()
    )
  end
end
