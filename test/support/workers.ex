defmodule MCPJobs.Test.SuccessWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"value" => value}}), do: {:ok, %{"value" => value}}
end

defmodule MCPJobs.Test.ValueWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, "done"}
end

defmodule MCPJobs.Test.PlainWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end

defmodule MCPJobs.Test.FlakyWorker do
  @moduledoc false
  use Oban.Worker, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{attempt: attempt, args: %{"succeed_on" => succeed_on}})
      when attempt >= succeed_on,
      do: {:ok, %{"attempt" => attempt}}

  def perform(%Oban.Job{}), do: {:error, "not yet"}
end

defmodule MCPJobs.Test.FailingWorker do
  @moduledoc false
  use Oban.Worker, max_attempts: 2

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:error, "boom"}
end

defmodule MCPJobs.Test.CrashingWorker do
  @moduledoc false
  use Oban.Worker, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: raise("crash")
end

defmodule MCPJobs.Test.CancelledDuringRunWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{meta: %{"mcp_task_id" => task_id}} = job) do
    {:ok, _task} = MCPJobs.cancel(task_id)

    if MCPJobs.cancelled?(job), do: {:cancel, :mcp_task_cancelled}, else: {:ok, %{}}
  end
end

defmodule MCPJobs.Test.DocumentedWorker do
  @moduledoc """
  Builds a summary.
  """

  use Oban.Worker

  use MCPJobs.Tool,
    input_schema: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end

defmodule MCPJobs.Test.HiddenDocWorker do
  @moduledoc false

  use Oban.Worker
  use MCPJobs.Tool, name: "hidden"

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end

defmodule MCPJobs.Test.ProWorker.Data do
  @moduledoc false
  def __args_schema__,
    do: [office_id: [required: true, type: :uuid], has_notes: [default: false, type: :boolean]]
end

defmodule MCPJobs.Test.ProWorker.Addresses do
  @moduledoc false
  def __args_schema__, do: [city: [type: :string]]
end

defmodule MCPJobs.Test.ProWorker do
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
      data: [cardinality: :one, module: MCPJobs.Test.ProWorker.Data, required: true, type: :embed],
      addresses: [
        cardinality: :many,
        module: MCPJobs.Test.ProWorker.Addresses,
        required: false,
        type: :embed
      ]
    ]
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end

defmodule MCPJobs.Test.UniqueWorker do
  @moduledoc false
  use Oban.Worker, unique: [period: 60]

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end

defmodule MCPJobs.Test.TupleWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, {:not, :json}}
end

defmodule MCPJobs.Test.NulWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, %{"text" => "a\u0000b"}}
end

defmodule MCPJobs.Test.ClientMessageWorker do
  @moduledoc false
  use Oban.Worker, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"atom_key" => true}}),
    do: {:error, %{message: "Chosen message.", secret: "s3"}}

  def perform(%Oban.Job{}), do: {:error, %{"message" => "Chosen message.", "secret" => "s3"}}
end

defmodule MCPJobs.Test.StructResultWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, ~U[2026-01-01 00:00:00Z]}
end

defmodule MCPJobs.Test.EscapedNulWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, %{"text" => "use \\u0000 to escape NUL"}}
end

defmodule MCPJobs.Test.ExceptionReasonWorker do
  @moduledoc false
  use Oban.Worker, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:error, %RuntimeError{message: "API key sk-secret was rejected"}}
end

defmodule MCPJobs.Test.NulStruct do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:text]
end

defmodule MCPJobs.Test.NulStructWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, %{"x" => %MCPJobs.Test.NulStruct{text: "a\u0000b"}}}
end
