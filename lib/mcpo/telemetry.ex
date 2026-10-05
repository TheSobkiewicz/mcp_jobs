defmodule MCPO.Telemetry do
  @moduledoc """
  Telemetry events that MCPO sends, and the Oban events it listens to.

  ## Events

    * `[:mcpo, :task, :started]`: a task and its Oban job are inserted.
    * `[:mcpo, :task, :completed]`
    * `[:mcpo, :task, :failed]`
    * `[:mcpo, :task, :cancelled]`

  Measurements: `:system_time` for `:started`. `:duration` for the other events,
  in native time units, from task insert to the status change.

  Metadata: `:task_id`, `:oban_job_id`, `:worker`.

  ## Oban events

  MCPO attaches to `[:oban, :job, :stop]` and `[:oban, :job, :exception]` when
  its application starts. It changes a task only when Oban reports a final state
  (`:success`, `:discard` or `:cancelled`). A `:failure` state is a retry, so the
  task stays `:working`.

  On `:success`, the return value of `perform/1` becomes the task result:
  `{:ok, map}` saves the map, `{:ok, value}` saves `%{"value" => value}`, and
  `:ok` saves no result. A result that cannot be saved as JSON makes the task
  `:failed`.
  """

  require Logger

  alias MCPO.Task

  @handler_id "mcpo-job-handler"

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
      :success -> complete(conf, task_id, result(meta))
      :discard -> MCPO.transition(conf, task_id, :failed, error: error(meta))
      :cancelled -> MCPO.transition(conf, task_id, :cancelled, [])
    end
  rescue
    exception ->
      Logger.error("[MCPO] telemetry handler failed: " <> Exception.message(exception))
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  @doc false
  @spec emit(Task.t()) :: :ok
  def emit(%Task{status: :working} = task) do
    :telemetry.execute(
      [:mcpo, :task, :started],
      %{system_time: System.system_time()},
      metadata(task)
    )
  end

  def emit(%Task{status: status, inserted_at: inserted_at, updated_at: updated_at} = task) do
    duration =
      updated_at
      |> DateTime.diff(inserted_at, :microsecond)
      |> System.convert_time_unit(:microsecond, :native)

    :telemetry.execute([:mcpo, :task, status], %{duration: duration}, metadata(task))
  end

  defp metadata(%Task{task_id: task_id, oban_job_id: job_id, worker: worker}) do
    %{task_id: task_id, oban_job_id: job_id, worker: worker}
  end

  defp complete(conf, task_id, result) do
    case storable(result) do
      :ok ->
        MCPO.transition(conf, task_id, :completed, result: result)

      {:error, reason} ->
        Logger.error("[MCPO] the result of task #{task_id} is not valid JSON: #{reason}")
        error = %{"message" => "The result could not be saved as JSON."}
        MCPO.transition(conf, task_id, :failed, error: error)
    end
  end

  # Checks the result with the JSON library that Postgrex uses for the column.
  # PostgreSQL also rejects the NUL character in jsonb.
  defp storable(nil), do: :ok

  defp storable(result) do
    json = Application.get_env(:postgrex, :json_library, Jason)

    if String.contains?(json.encode!(result), "\\u0000"),
      do: {:error, "contains a NUL character"},
      else: :ok
  rescue
    exception -> {:error, inspect(exception.__struct__)}
  end

  defp result(%{result: {:ok, result}}) when is_map(result), do: result
  defp result(%{result: {:ok, result}}), do: %{"value" => result}
  defp result(%{}), do: nil

  defp error(%{error: %{__exception__: true} = exception}),
    do: %{"message" => Exception.message(exception)}

  defp error(%{result: result}), do: %{"message" => inspect(result)}
end
