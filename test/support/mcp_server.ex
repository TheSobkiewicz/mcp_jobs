defmodule MCPO.Test.MCPServer do
  @moduledoc false
  use MCPO.ExMCP

  @impl ExMCP.Server.Handler
  def handle_list_tools(_cursor, state) do
    tool = %{
      "name" => "generate_report",
      "description" => "Generates a report in the background.",
      "inputSchema" => %{"type" => "object", "properties" => %{"value" => %{"type" => "integer"}}},
      "execution" => %{"taskSupport" => "optional"}
    }

    {:ok, [tool], nil, state}
  end

  @impl ExMCP.Server.Handler
  def handle_call_tool("generate_report", arguments, state) do
    create_task("generate_report", MCPO.Test.SuccessWorker, arguments, state)
  end

  def handle_call_tool("failing_report", arguments, state) do
    create_task("failing_report", MCPO.Test.FailingWorker, arguments, state)
  end

  def handle_call_tool("slow_report", arguments, state) do
    opts = Keyword.put(__task_store_options__(), :wait_timeout, 200)
    MCPO.ExMCP.create_task("slow_report", MCPO.Test.SuccessWorker, arguments, state, opts)
  end
end
