defmodule MCPOban do
  @moduledoc """
  Runs MCP tasks as Oban jobs.

  An MCP tool calls `enqueue/3` and immediately gets back a task. Oban runs the
  job. The MCP server reads the task with `status/2` or `get/2`, and cancels it
  with `cancel/2`.

  MCPOban does not implement the MCP protocol. An MCP server adapter translates
  these functions into MCP messages.

  ## Options

  All functions take an `:oban` option with the name of the Oban instance. The
  default is `Oban`, or the value of `config :mcp_oban, oban: MyApp.Oban`.
  MCPOban uses the repo and prefix of that Oban instance.
  """

  import Ecto.Query, only: [where: 3]

  alias MCPOban.Repository
  alias MCPOban.Status
  alias MCPOban.Task
  alias MCPOban.Telemetry

  @cancellable_states ~w(available scheduled retryable)

  @doc """
  Creates a task and inserts an Oban job for it in one transaction.

  ## Options

    * `:task_id`: the MCP task ID. A random ID is made when it is not given.
      When a task with this ID already exists, it is returned and no new job is
      inserted.
    * `:owner`: a map with the auth context of the task (for example a user ID).
    * `:meta`: a map of extra data for the MCP server adapter.
    * `:job`: options for `c:Oban.Worker.new/2`, such as `:queue` or `:scheduled_at`.
    * `:oban`: the Oban instance name.
  """
  @spec enqueue(module(), map(), keyword()) :: {:ok, Task.t()} | {:error, term()}
  def enqueue(worker, args, opts \\ []) when is_atom(worker) and is_map(args) do
    conf = config(opts)
    task_id = Keyword.get_lazy(opts, :task_id, &generate_task_id/0)

    attrs = %{
      task_id: task_id,
      worker: inspect(worker),
      owner: opts[:owner],
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
        Telemetry.emit(task)
        {:ok, task}

      {:ok, {:existing, task}} ->
        {:ok, task}

      {:error, reason} ->
        {:error, reason}
    end
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

  @doc "Returns true when the task with this ID is cancelled."
  @spec cancelled?(String.t(), keyword()) :: boolean()
  def cancelled?(task_id, opts) when is_binary(task_id) do
    match?(%Task{status: :cancelled}, Repository.get(config(opts), task_id))
  end

  @doc """
  Completes a working task with a result.

  `MCPOban.Worker` calls it for you. Use it when you write a plain `Oban.Worker`.
  Returns `{:error, :terminal}` when the task is not `:working`.
  """
  @spec complete(String.t(), map() | nil, keyword()) ::
          {:ok, Task.t()} | {:error, :not_found | :terminal}
  def complete(task_id, result, opts \\ []) when is_map(result) or is_nil(result) do
    finish(task_id, :completed, [result: result], opts)
  end

  @doc """
  Fails a working task with an error.

  Returns `{:error, :terminal}` when the task is not `:working`.
  """
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
        Telemetry.emit(task)
        {:ok, task}

      :noop ->
        :noop
    end
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

  defp final_state(%Oban.Job{state: state} = job) do
    case Status.from_oban_state(state) do
      :working -> :working
      :failed -> {:failed, error: last_error(job)}
      status -> {status, []}
    end
  end

  defp last_error(%Oban.Job{errors: []}), do: nil

  defp last_error(%Oban.Job{errors: errors}) do
    %{"error" => message} = Enum.max_by(errors, &Map.get(&1, "attempt", 0))
    %{"message" => message}
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

  defp config(opts) do
    opts
    |> Keyword.get_lazy(:oban, fn -> Application.get_env(:mcp_oban, :oban, Oban) end)
    |> Oban.config()
  end

  defp generate_task_id do
    Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end
