defmodule MCPOban.Test.MCPServer do
  @moduledoc false
  use MCPOban.ExMCP,
    tools: [
      {MCPOban.Test.SuccessWorker,
       name: "generate_report",
       description: "Generates a report in the background.",
       input_schema: %{"type" => "object", "properties" => %{"value" => %{"type" => "integer"}}}},
      {MCPOban.Test.FailingWorker, name: "failing_report"},
      MCPOban.Test.PlainWorker,
      MCPOban.Test.DocumentedWorker,
      {MCPOban.Test.DocumentedWorker, name: "summary_override", description: "Override."},
      MCPOban.Test.HiddenDocWorker,
      {MCPOban.Test.UniqueWorker, name: "unique_report"}
    ]

  @impl ExMCP.Server.Handler
  def handle_call_tool("slow_report", arguments, state) do
    opts = Keyword.put(__task_store_options__(), :wait_timeout, 200)
    MCPOban.ExMCP.create_task("slow_report", MCPOban.Test.SuccessWorker, arguments, state, opts)
  end

  def handle_call_tool("slow_kill_report", arguments, state) do
    opts = Keyword.merge(__task_store_options__(), wait_timeout: 200, kill: true)

    MCPOban.ExMCP.create_task(
      "slow_kill_report",
      MCPOban.Test.SuccessWorker,
      arguments,
      state,
      opts
    )
  end

  def handle_call_tool(name, arguments, state), do: super(name, arguments, state)
end
