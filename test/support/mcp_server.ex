defmodule MCPJobs.Test.MCPServer do
  @moduledoc false
  use MCPJobs.ExMCP,
    tools: [
      {MCPJobs.Test.SuccessWorker,
       name: "generate_report",
       description: "Generates a report in the background.",
       input_schema: %{"type" => "object", "properties" => %{"value" => %{"type" => "integer"}}}},
      {MCPJobs.Test.FailingWorker, name: "failing_report"},
      MCPJobs.Test.PlainWorker,
      MCPJobs.Test.DocumentedWorker,
      {MCPJobs.Test.DocumentedWorker, name: "summary_override", description: "Override."},
      MCPJobs.Test.HiddenDocWorker,
      {MCPJobs.Test.UniqueWorker, name: "unique_report"}
    ]

  @impl ExMCP.Server.Handler
  def handle_call_tool("slow_report", arguments, state) do
    opts = Keyword.put(__task_store_options__(), :wait_timeout, 200)
    MCPJobs.ExMCP.create_task("slow_report", MCPJobs.Test.SuccessWorker, arguments, state, opts)
  end

  def handle_call_tool("slow_kill_report", arguments, state) do
    opts = Keyword.merge(__task_store_options__(), wait_timeout: 200, kill: true)

    MCPJobs.ExMCP.create_task(
      "slow_kill_report",
      MCPJobs.Test.SuccessWorker,
      arguments,
      state,
      opts
    )
  end

  def handle_call_tool(name, arguments, state), do: super(name, arguments, state)
end
