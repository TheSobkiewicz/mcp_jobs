defmodule ReportServer.Workers.GenerateReport do
  @moduledoc """
  Builds a report in steps. It checks for cancellation before each step.
  """

  use MCPOban.Worker, queue: :reports, max_attempts: 3

  @impl MCPOban.Worker
  def run(%Oban.Job{args: %{"steps" => steps}} = job) do
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
