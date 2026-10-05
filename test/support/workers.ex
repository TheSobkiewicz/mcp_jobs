defmodule MCPO.Test.SuccessWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"value" => value}}), do: {:ok, %{"value" => value}}
end

defmodule MCPO.Test.ValueWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, "done"}
end

defmodule MCPO.Test.PlainWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end

defmodule MCPO.Test.FlakyWorker do
  @moduledoc false
  use Oban.Worker, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{attempt: attempt, args: %{"succeed_on" => succeed_on}})
      when attempt >= succeed_on,
      do: {:ok, %{"attempt" => attempt}}

  def perform(%Oban.Job{}), do: {:error, "not yet"}
end

defmodule MCPO.Test.FailingWorker do
  @moduledoc false
  use Oban.Worker, max_attempts: 2

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:error, "boom"}
end

defmodule MCPO.Test.CrashingWorker do
  @moduledoc false
  use Oban.Worker, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: raise("crash")
end

defmodule MCPO.Test.CancelledDuringRunWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{meta: %{"mcp_task_id" => task_id}} = job) do
    {:ok, _task} = MCPO.cancel(task_id)

    if MCPO.cancelled?(job), do: {:cancel, :mcp_task_cancelled}, else: {:ok, %{}}
  end
end

defmodule MCPO.Test.DocumentedWorker do
  @moduledoc """
  Builds a summary.
  """

  use Oban.Worker

  use MCPO.Tool,
    input_schema: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end

defmodule MCPO.Test.HiddenDocWorker do
  @moduledoc false

  use Oban.Worker
  use MCPO.Tool, name: "hidden"

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end

defmodule MCPO.Test.ProWorker.Data do
  @moduledoc false
  def __args_schema__,
    do: [office_id: [required: true, type: :uuid], has_notes: [default: false, type: :boolean]]
end

defmodule MCPO.Test.ProWorker.Addresses do
  @moduledoc false
  def __args_schema__, do: [city: [type: :string]]
end

defmodule MCPO.Test.ProWorker do
  @moduledoc false
  use Oban.Worker

  # The same format as `__args_schema__/0` of an Oban Pro structured worker.
  def __args_schema__ do
    [
      id: [required: true, type: :id],
      name: [required: true, type: :string],
      mode: [values: [:enabled, :disabled], default: :enabled, type: :enum],
      tags: [type: {:array, :string}],
      at: [type: :utc_datetime],
      xtra: [type: :term],
      data: [cardinality: :one, module: MCPO.Test.ProWorker.Data, required: true, type: :embed],
      addresses: [
        cardinality: :many,
        module: MCPO.Test.ProWorker.Addresses,
        required: false,
        type: :embed
      ]
    ]
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end
