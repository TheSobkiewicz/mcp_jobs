defmodule MCPOban.Task do
  @moduledoc """
  The link between an MCP task and the Oban job that does its work.

  `status` is `:working` until the task reaches a terminal status
  (`:completed`, `:failed` or `:cancelled`). A terminal status never changes.
  """

  use Ecto.Schema

  @statuses [:working, :completed, :failed, :cancelled]

  @type status :: :working | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          id: integer() | nil,
          task_id: String.t(),
          oban_job_id: integer() | nil,
          worker: String.t(),
          owner: map() | nil,
          status: status(),
          result: map() | nil,
          error: map() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "mcp_oban_tasks" do
    field :task_id, :string
    field :oban_job_id, :integer
    field :worker, :string
    field :owner, :map
    field :status, Ecto.Enum, values: @statuses, default: :working
    field :result, :map
    field :error, :map

    timestamps(type: :utc_datetime_usec)
  end

  @doc "All task statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Returns true when the task can no longer change."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: :working}), do: false
  def terminal?(%__MODULE__{}), do: true
end
