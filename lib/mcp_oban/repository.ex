defmodule MCPOban.Repository do
  @moduledoc false

  import Ecto.Query

  alias MCPOban.Task
  alias Oban.Config
  alias Oban.Repo

  @terminal_statuses Task.statuses() -- [:working]

  @spec insert(Config.t(), map()) :: {:inserted | :existing, Task.t()}
  def insert(%Config{} = conf, attrs) do
    task = struct(Task, attrs)

    case Repo.insert(conf, task, on_conflict: :nothing, conflict_target: :task_id) do
      {:ok, %Task{id: nil, task_id: task_id}} -> {:existing, get(conf, task_id)}
      {:ok, %Task{} = inserted} -> {:inserted, inserted}
    end
  end

  @spec get(Config.t(), String.t()) :: Task.t() | nil
  def get(%Config{} = conf, task_id) do
    Repo.get_by(conf, Task, task_id: task_id)
  end

  @spec put_job_id(Config.t(), String.t(), integer()) :: Task.t()
  def put_job_id(%Config{} = conf, task_id, job_id) do
    query = from(t in Task, where: t.task_id == ^task_id, select: t)
    {1, [task]} = Repo.update_all(conf, query, set: [oban_job_id: job_id])

    task
  end

  @spec put_progress(Config.t(), String.t(), map()) :: :ok
  def put_progress(%Config{} = conf, task_id, progress) do
    query = from(t in Task, where: t.task_id == ^task_id and t.status == ^:working)
    Repo.update_all(conf, query, set: [progress: progress, updated_at: DateTime.utc_now()])

    :ok
  end

  @doc """
  Moves a `:working` task to a terminal status. The `WHERE status = 'working'`
  condition makes the database pick one winner when changes race.
  """
  @spec transition(Config.t(), String.t(), Task.status(), keyword()) :: {:ok, Task.t()} | :noop
  def transition(%Config{} = conf, task_id, status, changes)
      when status in @terminal_statuses do
    query = from(t in Task, where: t.task_id == ^task_id and t.status == ^:working, select: t)
    set = [status: status, updated_at: DateTime.utc_now()] ++ changes

    case Repo.update_all(conf, query, set: set) do
      {1, [task]} -> {:ok, task}
      {0, []} -> :noop
    end
  end

  @spec delete_terminal_before(Config.t(), DateTime.t()) :: non_neg_integer()
  def delete_terminal_before(%Config{} = conf, cutoff) do
    query =
      from(t in Task, where: t.status in ^@terminal_statuses and t.updated_at < ^cutoff)

    {count, _} = Repo.delete_all(conf, query)

    count
  end

  @spec get_job(Config.t(), integer() | nil) :: Oban.Job.t() | nil
  def get_job(%Config{}, nil), do: nil
  def get_job(%Config{} = conf, job_id), do: Repo.get(conf, Oban.Job, job_id)
end
