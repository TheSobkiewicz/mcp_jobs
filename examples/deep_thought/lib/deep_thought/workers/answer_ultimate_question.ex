defmodule DeepThought.Workers.AnswerUltimateQuestion do
  @moduledoc """
  Computes the Answer to the Ultimate Question of Life, the Universe, and
  Everything. It takes 7.5 million years (about 3 seconds here).
  """

  use Oban.Worker, queue: :thinking, max_attempts: 3

  use MCPJobs.Tool,
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "question" => %{
          "type" => "string",
          "description" => "The question. The default is the Ultimate Question."
        }
      }
    }

  @ultimate_question "Life, the Universe, and Everything"

  @steps [
    "Warming up the circuits",
    "Thinking. 1.5 million years have passed",
    "Thinking. 3 million years have passed",
    "Thinking. 4.5 million years have passed",
    "Checking the result",
    "Checking the result again, very carefully"
  ]

  @mouse_step 3

  @impl Oban.Worker
  def backoff(%Oban.Job{}), do: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    case Map.get(args, "question", @ultimate_question) do
      "What is the Ultimate Question?" ->
        {:error,
         %{
           "message" =>
             "Deep Thought cannot compute the Ultimate Question. " <>
               "A much bigger computer must do it: the Earth.",
           "earth_location" => "ZZ9 Plural Z Alpha"
         }}

      _question ->
        think(job)
    end
  end

  defp think(%Oban.Job{attempt: attempt} = job) do
    total = length(@steps)

    @steps
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {step, number}, :ok ->
      cond do
        MCPJobs.cancelled?(job) ->
          {:halt, {:cancel, :earth_demolished_by_vogons}}

        attempt == 1 and number == @mouse_step ->
          MCPJobs.progress(job, number, total, "A mouse interrupted the calculation")
          {:halt, {:error, "A mouse interrupted the calculation. Starting again."}}

        true ->
          MCPJobs.progress(job, number, total, step)
          Process.sleep(500)
          {:cont, :ok}
      end
    end)
    |> case do
      :ok ->
        {:ok,
         %{
           "answer" => 42,
           "comment" =>
             "I checked it very thoroughly. The problem is that you never knew what the question was."
         }}

      stop ->
        stop
    end
  end
end
