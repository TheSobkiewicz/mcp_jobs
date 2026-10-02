defmodule MCPO.Test.MCPServer do
  @moduledoc false
  use MCPO.ExMCP,
    tools: [
      {MCPO.Test.SuccessWorker,
       name: "generate_report",
       description: "Generates a report in the background.",
       input_schema: %{"type" => "object", "properties" => %{"value" => %{"type" => "integer"}}}},
      {MCPO.Test.FailingWorker, name: "failing_report"},
      MCPO.Test.PlainWorker,
      MCPO.Test.DocumentedWorker,
      {MCPO.Test.DocumentedWorker, name: "summary_override", description: "Override."},
      MCPO.Test.HiddenDocWorker
    ]

  @impl ExMCP.Server.Handler
  def handle_call_tool("slow_report", arguments, state) do
    opts = Keyword.put(__task_store_options__(), :wait_timeout, 200)
    MCPO.ExMCP.create_task("slow_report", MCPO.Test.SuccessWorker, arguments, state, opts)
  end

  def handle_call_tool(name, arguments, state), do: super(name, arguments, state)
end
