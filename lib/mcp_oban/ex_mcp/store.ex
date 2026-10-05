if Code.ensure_loaded?(ExMCP.Tasks.Store) do
  defmodule MCPOban.ExMCP.Store do
    @moduledoc """
    An `ExMCP.Tasks.Store` that keeps tasks in the `mcp_oban_tasks` table.

    See `MCPOban.ExMCP` for the setup. Each task is bound to its ExMCP owner.
    A request from another owner gets `:not_found_or_unauthorized`.
    """

    @behaviour ExMCP.Tasks.Store

    alias ExMCP.Tasks.Task, as: MCPTask
    alias MCPOban.Task

    @internal_error -32_603

    @impl ExMCP.Tasks.Store
    def create(
          %MCPTask{
            id: task_id,
            tool_name: tool_name,
            arguments: arguments,
            ttl: ttl,
            poll_interval: poll_interval
          },
          owner,
          opts
        ) do
      enqueue_opts = [
        task_id: task_id,
        owner: normalize_owner(owner),
        meta: %{"tool_name" => tool_name, "ttl" => ttl, "poll_interval" => poll_interval},
        job: Keyword.get(opts, :job, [])
      ]

      with {:ok, worker} <- Keyword.fetch(opts, :worker),
           {:ok, task} <- MCPOban.enqueue(worker, arguments, enqueue_opts ++ oban_opts(opts)),
           :ok <- authorize(task, owner) do
        {:ok, to_mcp_task(task)}
      else
        :error -> {:error, :invalid_task}
        {:error, :not_found_or_unauthorized} -> {:error, :already_exists}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl ExMCP.Tasks.Store
    def fetch(task_id, owner, opts) do
      with {:ok, task} <- fetch_authorized(task_id, owner, opts), do: {:ok, to_mcp_task(task)}
    end

    @impl ExMCP.Tasks.Store
    def submit_input(task_id, _input_responses, owner, opts) do
      with {:ok, _task} <- fetch_authorized(task_id, owner, opts), do: :ok
    end

    @impl ExMCP.Tasks.Store
    def request_cancel(task_id, owner, opts) do
      with {:ok, _task} <- fetch_authorized(task_id, owner, opts) do
        cancel_opts = [kill: Keyword.get(opts, :kill, false)] ++ oban_opts(opts)

        case MCPOban.cancel(task_id, cancel_opts) do
          {:ok, _task} -> :ok
          {:error, :terminal} -> :ok
          {:error, :not_found} -> {:error, :not_found_or_unauthorized}
        end
      end
    end

    @impl ExMCP.Tasks.Store
    def transition(task_id, operation, owner, opts) do
      with {:ok, _task} <- fetch_authorized(task_id, owner, opts),
           {:ok, task} <- apply_transition(task_id, operation, oban_opts(opts)) do
        {:ok, to_mcp_task(task)}
      else
        {:error, :terminal} -> {:error, :invalid_transition}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl ExMCP.Tasks.Store
    def take_input_responses(task_id, owner, opts) do
      with {:ok, _task} <- fetch_authorized(task_id, owner, opts), do: {:ok, %{}}
    end

    @impl ExMCP.Tasks.Store
    def cancellation_requested?(task_id, owner, opts) do
      with {:ok, %Task{status: status}} <- fetch_authorized(task_id, owner, opts) do
        {:ok, status == :cancelled}
      end
    end

    defp apply_transition(task_id, {:complete, result}, opts),
      do: MCPOban.complete(task_id, result, opts)

    defp apply_transition(task_id, {:fail, error}, opts), do: MCPOban.fail(task_id, error, opts)
    defp apply_transition(task_id, :cancelled, opts), do: MCPOban.cancel(task_id, opts)
    defp apply_transition(_task_id, _operation, _opts), do: {:error, :invalid_transition}

    defp fetch_authorized(task_id, owner, opts) do
      with {:ok, task} <- MCPOban.get(task_id, oban_opts(opts)),
           :ok <- authorize(task, owner) do
        {:ok, task}
      else
        {:error, _reason} -> {:error, :not_found_or_unauthorized}
      end
    end

    defp authorize(%Task{owner: stored}, owner) do
      if stored == normalize_owner(owner), do: :ok, else: {:error, :not_found_or_unauthorized}
    end

    @doc false
    def normalize_owner(owner), do: MCPOban.__json_value__(owner)

    defp oban_opts(opts), do: Keyword.take(opts, [:oban])

    defp to_mcp_task(
           %Task{
             task_id: task_id,
             status: status,
             meta: meta,
             progress: progress,
             inserted_at: inserted_at,
             updated_at: updated_at
           } = task
         ) do
      %MCPTask{
        id: task_id,
        state: status,
        tool_name: Map.get(meta, "tool_name", ""),
        created_at: DateTime.to_iso8601(inserted_at),
        last_updated_at: DateTime.to_iso8601(updated_at),
        ttl: Map.get(meta, "ttl"),
        poll_interval: Map.get(meta, "poll_interval"),
        status_message: status_message(status, progress),
        result: call_tool_result(task),
        error: rpc_error(task)
      }
    end

    defp status_message(:working, progress), do: MCPOban.Status.progress_message(progress)
    defp status_message(_terminal, _progress), do: nil

    @doc false
    def call_tool_result(%Task{status: :completed, result: nil}), do: %{"content" => []}

    def call_tool_result(%Task{status: :completed, result: %{"content" => content} = result})
        when is_list(content),
        do: result

    def call_tool_result(%Task{status: :completed, result: result}) do
      %{
        "content" => [%{"type" => "text", "text" => JSON.encode!(result)}],
        "structuredContent" => result
      }
    end

    def call_tool_result(%Task{}), do: nil

    defp rpc_error(%Task{status: :failed, error: error}) do
      %{"code" => @internal_error, "message" => MCPOban.Status.error_message(error)}
    end

    defp rpc_error(%Task{}), do: nil
  end
end
