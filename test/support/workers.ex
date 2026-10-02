defmodule MCPOban.Test.SuccessWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"value" => value}}), do: {:ok, %{"value" => value}}
end

defmodule MCPOban.Test.ValueWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, "done"}
end

defmodule MCPOban.Test.PlainWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end

defmodule MCPOban.Test.FlakyWorker do
  @moduledoc false
  use Oban.Worker, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{attempt: attempt, args: %{"succeed_on" => succeed_on}})
      when attempt >= succeed_on,
      do: {:ok, %{"attempt" => attempt}}

  def perform(%Oban.Job{}), do: {:error, "not yet"}
end

defmodule MCPOban.Test.FailingWorker do
  @moduledoc false
  use Oban.Worker, max_attempts: 2

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:error, "boom"}
end

defmodule MCPOban.Test.CrashingWorker do
  @moduledoc false
  use Oban.Worker, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: raise("crash")
end

defmodule MCPOban.Test.CancelledDuringRunWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{meta: %{"mcp_task_id" => task_id}} = job) do
    {:ok, _task} = MCPOban.cancel(task_id)

    if MCPOban.cancelled?(job), do: {:cancel, :mcp_task_cancelled}, else: {:ok, %{}}
  end
end
