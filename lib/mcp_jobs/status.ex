defmodule MCPJobs.Status do
  @moduledoc """
  Maps Oban job states to MCP task statuses.

  | Oban state                                            | MCP status   |
  | ----------------------------------------------------- | ------------ |
  | `available`, `scheduled`, `executing`, `retryable`, `suspended` | `:working` |
  | `completed`                                           | `:completed` |
  | `discarded`                                           | `:failed`    |
  | `cancelled`, or the job is deleted                    | `:cancelled` |

  A `retryable` job is still `:working`. A retry never makes a task fail.
  """

  @working_states ~w(available scheduled executing retryable suspended)

  @doc "Returns the MCP status for an Oban job state. `nil` means the job is deleted."
  @spec from_oban_state(String.t() | nil) :: MCPJobs.Task.status()
  def from_oban_state(state) when state in @working_states, do: :working
  def from_oban_state("completed"), do: :completed
  def from_oban_state("discarded"), do: :failed
  def from_oban_state("cancelled"), do: :cancelled
  def from_oban_state(nil), do: :cancelled

  @doc "Formats a task as the map that `MCPJobs.status/2` returns."
  @spec to_map(MCPJobs.Task.t()) :: map()
  def to_map(%MCPJobs.Task{status: :completed, result: result}),
    do: %{status: :completed, result: result}

  def to_map(%MCPJobs.Task{status: :failed, error: error}), do: %{status: :failed, error: error}

  def to_map(%MCPJobs.Task{status: :working, progress: progress}),
    do: %{status: :working, progress: progress}

  def to_map(%MCPJobs.Task{status: status}), do: %{status: status}

  @doc false
  # A short text for MCP task status messages, for example "Rendering (2/5)".
  @spec progress_message(map() | nil) :: String.t() | nil
  def progress_message(nil), do: nil

  def progress_message(%{"current" => current} = progress) do
    count =
      case progress do
        %{"total" => total} when is_number(total) -> "#{current}/#{total}"
        _no_total -> "#{current}"
      end

    case progress do
      %{"message" => message} when is_binary(message) -> "#{message} (#{count})"
      _no_message -> count
    end
  end

  @failed_message "The task failed."

  @doc false
  @spec failed_message() :: String.t()
  def failed_message, do: @failed_message

  @doc false
  # The task error: a message for MCP clients and details for operators only.
  @spec failed_error(String.t() | nil) :: map()
  def failed_error(details), do: %{"message" => @failed_message, "details" => details}

  @doc false
  @spec error_message(map() | nil) :: String.t()
  def error_message(%{"message" => message}) when is_binary(message), do: message
  def error_message(_error), do: @failed_message
end
