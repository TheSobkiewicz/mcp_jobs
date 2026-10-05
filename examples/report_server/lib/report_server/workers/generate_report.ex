defmodule ReportServer.Workers.GenerateReport do
  @moduledoc """
  Generates a report in the background.
  """

  use Oban.Worker, queue: :reports, max_attempts: 3

  use MCPJobs.Tool,
    input_schema: %{
      "type" => "object",
      "properties" => %{"steps" => %{"type" => "integer", "minimum" => 1}},
      "required" => ["steps"]
    }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"steps" => steps}} = job) do
    Enum.reduce_while(1..steps, :ok, fn step, :ok ->
      if MCPJobs.cancelled?(job) do
        {:halt, {:cancel, :mcp_task_cancelled}}
      else
        Process.sleep(200)
        MCPJobs.progress(job, step, steps, "Wrote section #{step}")
        {:cont, :ok}
      end
    end)
    |> case do
      :ok -> {:ok, %{"report" => "Report with #{steps} sections"}}
      cancel -> cancel
    end
  end
end
