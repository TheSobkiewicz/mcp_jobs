defmodule DeepThought.MCPServer do
  @moduledoc """
  An MCP server with one long running tool. Each call runs as an Oban job.
  """

  use MCPJobs.ExMCP,
    server_info: %{"name" => "deep-thought", "version" => "0.1.0"},
    # Clients without MCP Tasks wait up to 5 minutes for a job.
    task_store_opts: [wait_timeout: 300_000],
    tools: [DeepThought.Workers.AnswerUltimateQuestion]
end
