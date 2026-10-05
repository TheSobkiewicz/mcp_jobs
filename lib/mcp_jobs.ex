defmodule MCPJobs do
  @moduledoc """
  Runs MCP tasks as Oban jobs.

  An MCP tool calls `enqueue/3` and immediately gets back a task. Oban runs the
  job. The MCP server reads the task with `status/2` or `get/2`, and cancels it
  with `cancel/2`.

  Workers are plain `Oban.Worker` modules. The return value of `perform/1`
  becomes the task result:

    * `{:ok, map}`: the task becomes `:completed` with the map as its result.
    * `{:ok, value}`: the result is `%{"value" => value}`. This includes
      structs such as `DateTime` or `Decimal`.
    * `:ok`: the task becomes `:completed` with no result.
    * `{:error, reason}`: Oban retries the job and the task stays `:working`.

  The result is stored as JSON, so atom keys come back as strings. A result
  that cannot be stored as JSON makes the task `:failed`.

  When the job fails for good, the task error is
  `%{"message" => "The task failed.", "details" => ...}`. MCP adapters send only
  `"message"` to clients, because the details can hold internal data. To choose
  the client message, return `{:error, %{"message" => "..."}}` from `perform/1`.

  Oban marks the job completed before MCPJobs saves the result. Until the result
  is saved, the task stays `:working`. If the result is not saved within 5
  seconds (for example, the node stopped), the task becomes `:completed` with no
  result. Change the time with `config :mcp_jobs, result_grace_period: 5_000`.

  When Oban deletes a job before MCPJobs sees its final state (for example, the
  Pruner removed it), the task becomes `:cancelled`. Keep the Pruner `max_age`
  longer than the time clients take to read a result.

  A worker with Oban `unique:` options cannot share a job between tasks:
  `enqueue/3` returns `{:error, :job_conflict}` for a duplicate job. With
  Oban's default unique states, a job that has already completed within the
  unique period also counts as a duplicate.

  MCPJobs does not implement the MCP protocol. An MCP server adapter translates
  these functions into MCP messages.

  MCPJobs needs PostgreSQL. It does not work with the MySQL or SQLite engines
  of Oban.

  ## Options

  All functions take an `:oban` option with the name of the Oban instance. The
  default is `Oban`, or the value of `config :mcp_jobs, oban: MyApp.Oban`.
  MCPJobs uses the repo and prefix of that Oban instance.
  """

  import Ecto.Query, only: [where: 3]

  alias MCPJobs.Repository
  alias MCPJobs.Status
  alias MCPJobs.Task
  alias MCPJobs.Telemetry

  @cancellable_states ~w(available scheduled retryable suspended)
  @result_grace_period 5_000

  @doc """
  Creates a task and inserts an Oban job for it in one transaction.

  ## Options

    * `:task_id`: the MCP task ID. A random ID is made when it is not given.
      When a task with this ID already exists for the same worker and owner,
      it is returned and no new job is inserted. When the worker or the owner
      is different, `{:error, :already_exists}` is returned.
    * `:owner`: a map with the auth context of the task (for example a user ID).
    * `:meta`: a map of extra data for the MCP server adapter.
    * `:job`: options for `c:Oban.Worker.new/2`, such as `:queue` or `:scheduled_at`.
    * `:oban`: the Oban instance name.
  """
  @spec enqueue(module(), map(), keyword()) :: {:ok, Task.t()} | {:error, term()}
  def enqueue(worker, args, opts \\ []) when is_atom(worker) and is_map(args) do
    conf = config(opts)
    task_id = Keyword.get_lazy(opts, :task_id, &generate_task_id/0)
    worker_name = inspect(worker)
    owner = __json_value__(Keyword.get(opts, :owner))

    attrs = %{
      task_id: task_id,
      worker: worker_name,
      owner: owner,
      meta: Keyword.get(opts, :meta, %{})
    }

    result =
      Oban.Repo.transaction(conf, fn ->
        case Repository.insert(conf, attrs) do
          {:existing, task} -> {:existing, task}
          {:inserted, _task} -> {:inserted, insert_job(conf, worker, args, task_id, opts)}
        end
      end)

    case result do
      {:ok, {:inserted, task}} ->
        Telemetry.emit(conf, task)
        {:ok, task}

      {:ok, {:existing, %Task{owner: stored_owner, worker: ^worker_name} = task}} ->
        if stored_owner == owner, do: {:ok, task}, else: {:error, :already_exists}

      {:ok, {:existing, %Task{}}} ->
        {:error, :already_exists}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # The owner is stored as JSON. Converting it the same way first makes the
  # stored and the requested owner comparable, for example atom values.
  @spec __json_value__(term()) :: term()
  def __json_value__(nil), do: nil

  def __json_value__(value) do
    json = Application.get_env(:postgrex, :json_library, Jason)
    value |> json.encode!() |> json.decode!()
  end

  @doc """
  Returns the status of a task.

      {:ok, %{status: :working}}
      {:ok, %{status: :completed, result: %{"url" => "..."}}}
      {:ok, %{status: :failed, error: %{"message" => "..."}}}
      {:ok, %{status: :cancelled}}
  """
  @spec status(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def status(task_id, opts \\ []) do
    with {:ok, task} <- get(task_id, opts), do: {:ok, Status.to_map(task)}
  end

  @doc """
  Returns the task.

  When the task is `:working` but its Oban job is in a final state, the task is
  changed to match the job first. This repairs tasks that missed an Oban event.
  """
  @spec get(String.t(), keyword()) :: {:ok, Task.t()} | {:error, :not_found}
  def get(task_id, opts \\ []) do
    conf = config(opts)

    case Repository.get(conf, task_id) do
      nil -> {:error, :not_found}
      %Task{status: :working} = task -> {:ok, sync_with_job(conf, task)}
      %Task{} = task -> {:ok, task}
    end
  end

  @doc """
  Waits until the task is completed, failed or cancelled, and returns it.

  Use it for clients that cannot poll a task. The caller process is blocked
  while it waits. The task is not cancelled on timeout.

  ## Options

    * `:timeout`: the maximum wait in milliseconds, or `:infinity`. The default
      is 5000.
    * `:interval`: the time between two status checks in milliseconds. The
      default is 100.
    * `:on_progress`: a function that gets the new progress map (see
      `progress/4`) each time it changes while the task is working. The
      `"current"` value always increases, as MCP progress must. A retry starts
      again from a lower value, so the values after it continue from the last
      value: `"current"` and `"total"` get that value added. A change that does
      not increase `"current"` is not sent.
    * `:oban`: the Oban instance name.
  """
  @spec await(String.t(), keyword()) :: {:ok, Task.t()} | {:error, :not_found | :timeout}
  def await(task_id, opts \\ []) do
    deadline =
      case Keyword.get(opts, :timeout, 5_000) do
        :infinity -> :infinity
        timeout -> System.monotonic_time(:millisecond) + timeout
      end

    reported = %{last: nil, sent: nil, offset: 0}
    poll(task_id, deadline, Keyword.get(opts, :interval, 100), reported, opts)
  end

  @doc false
  # Ends a wait that timed out: cancels the task, or returns it when it
  # finished between the last check and the cancel.
  @spec __cancel_after_timeout__(String.t(), keyword()) ::
          {:cancelled, Task.t()} | {:finished, Task.t()} | {:error, :not_found}
  def __cancel_after_timeout__(task_id, opts) do
    case cancel(task_id, opts) do
      {:ok, task} -> {:cancelled, task}
      {:error, :terminal} -> with {:ok, task} <- get(task_id, opts), do: {:finished, task}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Cancels a task.

  The task becomes `:cancelled` at once. A job that waits to run is cancelled in
  Oban. A job that is running is not stopped: the worker can check `cancelled?/1`
  and stop. Its result is not saved.

  ## Options

    * `:kill`: when `true`, a running job is also stopped by Oban. Oban kills the
      process, so the job cannot clean up. The default is `false`.
    * `:oban`: the Oban instance name.

  Returns `{:error, :terminal}` when the task is already completed, failed or
  cancelled.
  """
  @spec cancel(String.t(), keyword()) :: {:ok, Task.t()} | {:error, :not_found | :terminal}
  def cancel(task_id, opts \\ []) do
    conf = config(opts)

    case transition(conf, task_id, :cancelled, []) do
      {:ok, task} ->
        cancel_job(conf, task, Keyword.get(opts, :kill, false))
        {:ok, task}

      :noop ->
        noop_error(conf, task_id)
    end
  end

  @doc """
  Returns true when the task of this job is cancelled. Use it in a long running worker.
  """
  @spec cancelled?(Oban.Job.t()) :: boolean()
  def cancelled?(%Oban.Job{meta: %{"mcp_task_id" => task_id}, conf: conf}) do
    match?(%Task{status: :cancelled}, Repository.get(conf, task_id))
  end

  def cancelled?(%Oban.Job{}), do: false

  @doc """
  Reports the progress of the task of this job. Use it in a long running worker:

      MCPJobs.progress(job, 2, 5, "Rendering the report")

  `current` and `total` are numbers, and `current` should grow. The progress is
  saved while the task is `:working`. `status/2` returns it, and the MCP
  adapters show it to clients. A job without a task is ignored.
  """
  @spec progress(Oban.Job.t(), number(), number() | nil, String.t() | nil) :: :ok
  def progress(job, current, total \\ nil, message \\ nil)

  def progress(%Oban.Job{meta: %{"mcp_task_id" => task_id}, conf: conf}, current, total, message)
      when is_number(current) and (is_nil(total) or is_number(total)) and
             (is_nil(message) or is_binary(message)) do
    progress =
      %{"current" => current, "total" => total, "message" => message}
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    case Repository.put_progress(conf, task_id, progress) do
      {:ok, task} -> Telemetry.emit_progress(conf, task)
      :noop -> :ok
    end
  end

  def progress(%Oban.Job{meta: meta}, _current, _total, _message)
      when not is_map_key(meta, "mcp_task_id"),
      do: :ok

  @doc false
  @spec complete(String.t(), map() | nil, keyword()) ::
          {:ok, Task.t()} | {:error, :not_found | :terminal}
  def complete(task_id, result, opts \\ []) when is_map(result) or is_nil(result) do
    finish(task_id, :completed, [result: result], opts)
  end

  @doc false
  @spec fail(String.t(), map(), keyword()) ::
          {:ok, Task.t()} | {:error, :not_found | :terminal}
  def fail(task_id, error, opts \\ []) when is_map(error) do
    finish(task_id, :failed, [error: error], opts)
  end

  @doc false
  @spec transition(Oban.Config.t(), String.t(), Task.status(), keyword()) ::
          {:ok, Task.t()} | :noop
  def transition(conf, task_id, status, changes) do
    case Repository.transition(conf, task_id, status, changes) do
      {:ok, task} ->
        Telemetry.emit(conf, task)
        {:ok, task}

      :noop ->
        :noop
    end
  end

  defp poll(task_id, deadline, interval, reported, opts) do
    case get_for_poll(task_id, opts) do
      {:ok, %Task{status: :working, progress: progress}} ->
        reported = report_progress(progress, reported, opts)

        case remaining(deadline) do
          :expired ->
            {:error, :timeout}

          remaining ->
            Process.sleep(min(interval, remaining))
            poll(task_id, deadline, interval, reported, opts)
        end

      result ->
        result
    end
  end

  defp remaining(:infinity), do: :infinity

  defp remaining(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> remaining
      _passed -> :expired
    end
  end

  defp report_progress(nil, reported, _opts), do: reported
  defp report_progress(progress, %{last: progress} = reported, _opts), do: reported

  defp report_progress(%{"current" => current} = progress, reported, opts) do
    offset = progress_offset(current, reported)
    value = current + offset

    case reported do
      %{sent: sent} when is_number(sent) and value <= sent ->
        %{reported | last: progress, offset: offset}

      _increases ->
        with on_progress when is_function(on_progress, 1) <- Keyword.get(opts, :on_progress) do
          on_progress.(shift_progress(progress, offset))
        end

        %{last: progress, sent: value, offset: offset}
    end
  end

  # A lower value than the last one means that a retry started again.
  defp progress_offset(current, %{last: %{"current" => last}, sent: sent}) when current < last,
    do: sent

  defp progress_offset(_current, %{offset: offset}), do: offset

  defp shift_progress(progress, 0), do: progress

  defp shift_progress(%{"current" => current} = progress, offset) do
    Map.replace_lazy(%{progress | "current" => current + offset}, "total", &(&1 + offset))
  end

  # A short database outage must not end a long wait: the job keeps running.
  defp get_for_poll(task_id, opts) do
    get(task_id, opts)
  rescue
    DBConnection.ConnectionError -> {:ok, %Task{status: :working}}
  end

  defp finish(task_id, status, changes, opts) do
    conf = config(opts)

    case transition(conf, task_id, status, changes) do
      {:ok, task} -> {:ok, task}
      :noop -> noop_error(conf, task_id)
    end
  end

  defp noop_error(conf, task_id) do
    if Repository.get(conf, task_id), do: {:error, :terminal}, else: {:error, :not_found}
  end

  defp insert_job(%Oban.Config{name: name} = conf, worker, args, task_id, opts) do
    job_opts =
      opts
      |> Keyword.get(:job, [])
      |> Keyword.update(:meta, %{"mcp_task_id" => task_id}, &Map.put(&1, "mcp_task_id", task_id))

    case Oban.insert(name, worker.new(args, job_opts)) do
      {:ok, %Oban.Job{conflict?: true}} -> Oban.Repo.rollback(conf, :job_conflict)
      {:ok, %Oban.Job{id: job_id}} -> Repository.put_job_id(conf, task_id, job_id)
      {:error, reason} -> Oban.Repo.rollback(conf, reason)
    end
  end

  defp sync_with_job(conf, %Task{task_id: task_id, oban_job_id: job_id} = task) do
    case final_state(Repository.get_job(conf, job_id)) do
      :working ->
        task

      {status, changes} ->
        case transition(conf, task_id, status, changes) do
          {:ok, synced} -> synced
          :noop -> Repository.get(conf, task_id)
        end
    end
  end

  defp final_state(nil), do: {:cancelled, []}

  defp final_state(
         %Oban.Job{state: state, completed_at: completed_at, discarded_at: discarded_at} = job
       ) do
    case Status.from_oban_state(state) do
      :working -> :working
      :completed -> if pending?(completed_at), do: :working, else: {:completed, []}
      :failed -> if pending?(discarded_at), do: :working, else: {:failed, error: last_error(job)}
      status -> {status, []}
    end
  end

  # Oban saves the final job state before the telemetry event saves the result
  # or the worker's error message. Repairing the task in this window would lose
  # them.
  defp pending?(nil), do: false

  defp pending?(finished_at) do
    grace = Application.get_env(:mcp_jobs, :result_grace_period, @result_grace_period)
    DateTime.diff(DateTime.utc_now(), finished_at, :millisecond) < grace
  end

  defp last_error(%Oban.Job{errors: []}), do: Status.failed_error(nil)

  defp last_error(%Oban.Job{errors: errors}) do
    %{"error" => details} = Enum.max_by(errors, &Map.get(&1, "attempt", 0))
    Status.failed_error(details)
  end

  defp cancel_job(_conf, %Task{oban_job_id: nil}, _kill), do: :ok

  defp cancel_job(%Oban.Config{name: name}, %Task{oban_job_id: job_id}, true),
    do: Oban.cancel_job(name, job_id)

  defp cancel_job(%Oban.Config{name: name}, %Task{oban_job_id: job_id}, false) do
    query =
      Oban.Job
      |> where([j], j.id == ^job_id)
      |> where([j], j.state in @cancellable_states)

    {:ok, _count} = Oban.cancel_all_jobs(name, query)

    :ok
  end

  @doc false
  @spec __config__(keyword()) :: Oban.Config.t()
  def __config__(opts), do: config(opts)

  defp config(opts) do
    opts
    |> Keyword.get_lazy(:oban, fn -> Application.get_env(:mcp_jobs, :oban, Oban) end)
    |> Oban.config()
  end

  defp generate_task_id do
    Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end
