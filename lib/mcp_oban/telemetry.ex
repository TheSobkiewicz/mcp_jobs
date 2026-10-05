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
  task stays `:working`. When a `:failure` or `:snoozed` job belongs to a task that
  is already cancelled, MCPOban cancels the job, so it does not run again.

  On `:success`, the return value of `perform/1` becomes the task result:
  `{:ok, map}` saves the map, `{:ok, value}` saves `%{"value" => value}`, and
  `:ok` saves no result. A result that cannot be saved as JSON makes the task
  `:failed`.
  """

  require Logger

  alias MCPOban.Status
  alias MCPOban.Task

  @handler_id "mcp_oban-job-handler"

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
      :discard -> MCPOban.transition(conf, task_id, :failed, error: error(meta))
      :cancelled -> MCPOban.transition(conf, task_id, :cancelled, [])
    end
  rescue
    exception ->
      Logger.error("[MCPOban] telemetry handler failed: " <> Exception.message(exception))
  end

  # A task that was cancelled while its job ran must not run again on a retry.
  def handle_event(
        [:oban, :job, _event],
        _measurements,
        %{
          job: %Oban.Job{id: job_id, meta: %{"mcp_task_id" => task_id}},
          state: state,
          conf: %Oban.Config{name: name} = conf
        },
        _config
      )
      when state in [:failure, :snoozed] do
    case MCPOban.Repository.get(conf, task_id) do
      %Task{status: :cancelled} -> Oban.cancel_job(name, job_id)
      _working_or_missing -> :ok
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

  defp complete(conf, task_id, result) do
    case storable(result) do
      :ok ->
        MCPOban.transition(conf, task_id, :completed, result: result)

      {:error, reason} ->
        Logger.error("[MCPOban] the result of task #{task_id} is not valid JSON: #{reason}")

        error =
          Map.put(
            Status.failed_error(reason),
            "message",
            "The result could not be saved as JSON."
          )

        MCPOban.transition(conf, task_id, :failed, error: error)
    end
  end

  # Checks the result with the JSON library that Postgrex uses for the column.
  # PostgreSQL also rejects the NUL character in jsonb.
  defp storable(nil), do: :ok

  defp storable(result) do
    json = Application.get_env(:postgrex, :json_library, Jason)
    decoded = result |> json.encode!() |> json.decode!()

    if nul?(decoded), do: {:error, "contains a NUL character"}, else: :ok
  rescue
    exception -> {:error, inspect(exception.__struct__)}
  end

  defp nul?(value) when is_binary(value), do: String.contains?(value, <<0>>)
  defp nul?(value) when is_list(value), do: Enum.any?(value, &nul?/1)
  defp nul?(value) when is_map(value), do: Enum.any?(value, fn {k, v} -> nul?(k) or nul?(v) end)
  defp nul?(_value), do: false

  defp result(%{result: {:ok, result}}) when is_map(result) and not is_struct(result),
    do: result

  defp result(%{result: {:ok, result}}), do: %{"value" => result}
  defp result(%{}), do: nil

  defp error(meta),
    do: Map.put(Status.failed_error(details(meta)), "message", client_message(meta))

  # A worker chooses the message that MCP clients see by returning
  # `{:error, %{"message" => ...}}`. Other errors, also exception structs, can
  # hold internal data, so clients only get a fixed message.
  defp client_message(%{result: {kind, %{"message" => message} = reason}})
       when kind in [:error, :discard] and is_binary(message) and not is_struct(reason),
       do: message

  defp client_message(%{result: {kind, %{message: message} = reason}})
       when kind in [:error, :discard] and is_binary(message) and not is_struct(reason),
       do: message

  defp client_message(_meta), do: Status.failed_message()

  defp details(%{error: %{__exception__: true} = exception}), do: Exception.message(exception)
  defp details(%{result: result}), do: inspect(result)
end
