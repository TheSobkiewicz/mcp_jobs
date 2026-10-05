defmodule ReportServer.Workers.GenerateReport do
  @moduledoc """
  Generates a report in the background.
  """

  use Oban.Worker, queue: :reports, max_attempts: 3

  use MCPOban.Tool,
    input_schema: %{
      "type" => "object",
      "properties" => %{"steps" => %{"type" => "integer", "minimum" => 1}},
      "required" => ["steps"]
    }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"steps" => steps}} = job) do
    Enum.reduce_while(1..steps, :ok, fn _step, :ok ->
      if MCPOban.cancelled?(job) do
        {:halt, {:cancel, :mcp_task_cancelled}}
      else
        Process.sleep(200)
        {:cont, :ok}
      end
    end)
    |> case do
      :ok -> {:ok, %{"report" => "Report with #{steps} sections"}}
      cancel -> cancel
    end
  end
end
