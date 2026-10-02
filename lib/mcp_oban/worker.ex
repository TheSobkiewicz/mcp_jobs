defmodule MCPOban.Worker do
  @moduledoc """
  An Oban worker that saves its result for the MCP task.

  Use it in place of `Oban.Worker`. It takes the same options. Write `run/1`
  in place of `perform/1`:

      defmodule MyApp.Workers.GenerateReport do
        use MCPOban.Worker, queue: :reports, max_attempts: 3

        @impl MCPOban.Worker
        def run(%Oban.Job{args: %{"report_id" => report_id}}) do
          {:ok, %{"url" => MyApp.Reports.generate(report_id)}}
        end
      end

  ## Return values

    * `{:ok, result}`: the task becomes `:completed` with `result`. A result that
      is not a map is saved as `%{"value" => result}`. The result is stored as
      JSON, so atom keys come back as strings.
    * `:ok`: the task becomes `:completed` with a `nil` result.
    * Any other value goes to Oban without change. For example, `{:error, reason}`
      makes Oban retry the job, and the task stays `:working`.

  ## Cancellation

  `MCPOban.cancel/2` does not stop a job that is running. A long job can check
  `MCPOban.cancelled?/1` and stop:

      def run(%Oban.Job{} = job) do
        if MCPOban.cancelled?(job), do: {:cancel, :mcp_task_cancelled}, else: do_work(job)
      end

  The worker does not call `run/1` when the task is already cancelled.
  """

  alias MCPOban.Task

  @doc "Does the work of the job."
  @callback run(Oban.Job.t()) :: :ok | {:ok, term()} | term()

  defmacro __using__(opts) do
    quote do
      use Oban.Worker, unquote(opts)

      @behaviour MCPOban.Worker

      @impl Oban.Worker
      def perform(%Oban.Job{} = job), do: MCPOban.Worker.perform(__MODULE__, job)
    end
  end

  @doc false
  @spec perform(module(), Oban.Job.t()) :: term()
  def perform(worker, %Oban.Job{meta: %{"mcp_task_id" => task_id}, conf: conf} = job) do
    case MCPOban.Repository.get(conf, task_id) do
      %Task{status: :working} -> run(worker, job, conf, task_id)
      %Task{status: :cancelled} -> {:cancel, :mcp_task_cancelled}
      _terminal_or_deleted -> :ok
    end
  end

  def perform(worker, %Oban.Job{} = job), do: worker.run(job)

  defp run(worker, job, conf, task_id) do
    case worker.run(job) do
      :ok ->
        complete(conf, task_id, nil)

      {:ok, result} when is_map(result) ->
        complete(conf, task_id, result)

      {:ok, result} ->
        complete(conf, task_id, %{"value" => result})

      other ->
        other
    end
  end

  defp complete(conf, task_id, result) do
    MCPOban.transition(conf, task_id, :completed, result: result)

    :ok
  end
end
