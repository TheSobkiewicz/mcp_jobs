defmodule MCPOban.Test.MCPServer do
  @moduledoc false
  use MCPOban.ExMCP

  @impl ExMCP.Server.Handler
  def handle_list_tools(_cursor, state) do
    tool = %{
      "name" => "generate_report",
      "description" => "Generates a report in the background.",
      "inputSchema" => %{"type" => "object", "properties" => %{"value" => %{"type" => "integer"}}},
      "execution" => %{"taskSupport" => "required"}
    }

    {:ok, [tool], nil, state}
  end

  @impl ExMCP.Server.Handler
  def handle_call_tool("generate_report", arguments, state) do
    create_task("generate_report", MCPOban.Test.SuccessWorker, arguments, state)
  end
end
