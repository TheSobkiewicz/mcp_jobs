defmodule MCPO.Status do
  @moduledoc """
  Maps Oban job states to MCP task statuses.

  | Oban state                                            | MCP status   |
  | ----------------------------------------------------- | ------------ |
  | `available`, `scheduled`, `executing`, `retryable`    | `:working`   |
  | `completed`                                           | `:completed` |
  | `discarded`                                           | `:failed`    |
  | `cancelled`, or the job is deleted                    | `:cancelled` |

  A `retryable` job is still `:working`. A retry never makes a task fail.
  """

  @working_states ~w(available scheduled executing retryable)

  @doc "Returns the MCP status for an Oban job state. `nil` means the job is deleted."
  @spec from_oban_state(String.t() | nil) :: MCPO.Task.status()
  def from_oban_state(state) when state in @working_states, do: :working
  def from_oban_state("completed"), do: :completed
  def from_oban_state("discarded"), do: :failed
  def from_oban_state("cancelled"), do: :cancelled
  def from_oban_state(nil), do: :cancelled

  @doc "Formats a task as the map that `MCPO.status/2` returns."
  @spec to_map(MCPO.Task.t()) :: map()
  def to_map(%MCPO.Task{status: :completed, result: result}),
    do: %{status: :completed, result: result}

  def to_map(%MCPO.Task{status: :failed, error: error}), do: %{status: :failed, error: error}
  def to_map(%MCPO.Task{status: status}), do: %{status: status}
end
