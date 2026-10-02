defmodule MCPOban.Telemetry do
  @moduledoc """
  Telemetry events that MCPOban sends, and the Oban events it listens to.

  ## Events

    * `[:mcp_oban, :task, :started]`: a task and its Oban job are inserted.
    * `[:mcp_oban, :task, :completed]`
    * `[:mcp_oban, :task, :failed]`
    * `[:mcp_oban, :task, :cancelled]`

  Measurements: `:system_time` for `:started`. `:duration` for the other events,
  in native time units, from task insert to the status change.

  Metadata: `:task_id`, `:oban_job_id`, `:worker`.

  ## Oban events

  MCPOban attaches to `[:oban, :job, :stop]` and `[:oban, :job, :exception]` when
  its application starts. It changes a task only when Oban reports a final state
  (`:success`, `:discard` or `:cancelled`). A `:failure` state is a retry, so the
  task stays `:working`.

  On `:success`, the return value of `perform/1` becomes the task result:
  `{:ok, map}` saves the map, `{:ok, value}` saves `%{"value" => value}`, and
  `:ok` saves no result.
  """

  require Logger

  alias MCPOban.Task

  @handler_id "mcp-oban-job-handler"

  @doc false
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach_many(
      @handler_id,
      [[:oban, :job, :stop], [:oban, :job, :exception]],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  def handle_event(
        [:oban, :job, _event],
        _measurements,
        %{job: %Oban.Job{meta: %{"mcp_task_id" => task_id}}, state: state, conf: conf} = meta,
        _config
      )
      when state in [:success, :discard, :cancelled] do
    case state do
      :success -> MCPOban.transition(conf, task_id, :completed, result: result(meta))
      :discard -> MCPOban.transition(conf, task_id, :failed, error: error(meta))
      :cancelled -> MCPOban.transition(conf, task_id, :cancelled, [])
    end
  rescue
    exception ->
      Logger.error("[MCPOban] telemetry handler failed: " <> Exception.message(exception))
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  @doc false
  @spec emit(Task.t()) :: :ok
  def emit(%Task{status: :working} = task) do
    :telemetry.execute(
      [:mcp_oban, :task, :started],
      %{system_time: System.system_time()},
      metadata(task)
    )
  end

  def emit(%Task{status: status, inserted_at: inserted_at, updated_at: updated_at} = task) do
    duration =
      updated_at
      |> DateTime.diff(inserted_at, :microsecond)
      |> System.convert_time_unit(:microsecond, :native)

    :telemetry.execute([:mcp_oban, :task, status], %{duration: duration}, metadata(task))
  end

  defp metadata(%Task{task_id: task_id, oban_job_id: job_id, worker: worker}) do
    %{task_id: task_id, oban_job_id: job_id, worker: worker}
  end

  defp result(%{result: {:ok, result}}) when is_map(result), do: result
  defp result(%{result: {:ok, result}}), do: %{"value" => result}
  defp result(%{}), do: nil

  defp error(%{error: %{__exception__: true} = exception}),
    do: %{"message" => Exception.message(exception)}

  defp error(%{result: result}), do: %{"message" => inspect(result)}
end
