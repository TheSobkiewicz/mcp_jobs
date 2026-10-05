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

defmodule MCPOban.Test.DocumentedWorker do
  @moduledoc """
  Builds a summary.
  """

  use Oban.Worker

  use MCPOban.Tool,
    input_schema: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end

defmodule MCPOban.Test.HiddenDocWorker do
  @moduledoc false

  use Oban.Worker
  use MCPOban.Tool, name: "hidden"

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end

defmodule MCPOban.Test.ProWorker.Data do
  @moduledoc false
  def __args_schema__,
    do: [office_id: [required: true, type: :uuid], has_notes: [default: false, type: :boolean]]
end

defmodule MCPOban.Test.ProWorker.Addresses do
  @moduledoc false
  def __args_schema__, do: [city: [type: :string]]
end

defmodule MCPOban.Test.ProWorker do
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
      data: [cardinality: :one, module: MCPOban.Test.ProWorker.Data, required: true, type: :embed],
      addresses: [
        cardinality: :many,
        module: MCPOban.Test.ProWorker.Addresses,
        required: false,
        type: :embed
      ]
    ]
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end

defmodule MCPOban.Test.UniqueWorker do
  @moduledoc false
  use Oban.Worker, unique: [period: 60]

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end

defmodule MCPOban.Test.TupleWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, {:not, :json}}
end

defmodule MCPOban.Test.NulWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, %{"text" => "a\u0000b"}}
end

defmodule MCPOban.Test.ClientMessageWorker do
  @moduledoc false
  use Oban.Worker, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"atom_key" => true}}),
    do: {:error, %{message: "Chosen message.", secret: "s3"}}

  def perform(%Oban.Job{}), do: {:error, %{"message" => "Chosen message.", "secret" => "s3"}}
end

defmodule MCPOban.Test.StructResultWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, ~U[2026-01-01 00:00:00Z]}
end

defmodule MCPOban.Test.EscapedNulWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, %{"text" => "use \\u0000 to escape NUL"}}
end

defmodule MCPOban.Test.ExceptionReasonWorker do
  @moduledoc false
  use Oban.Worker, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:error, %RuntimeError{message: "API key sk-secret was rejected"}}
end

defmodule MCPOban.Test.NulStruct do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:text]
end

defmodule MCPOban.Test.NulStructWorker do
  @moduledoc false
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, %{"x" => %MCPOban.Test.NulStruct{text: "a\u0000b"}}}
end
