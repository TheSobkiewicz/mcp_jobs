if Code.ensure_loaded?(ExMCP.Server.Subscriptions) do
  defmodule MCPJobs.ExMCP.Notifications do
    @moduledoc false

    # Sends `notifications/tasks` to ExMCP clients that listen for a task.
    # ExMCP sends it only for changes it makes itself. Job results, failures
    # and progress come from Oban, so this module sends them.

    require Logger

    alias ExMCP.Server.Subscriptions
    alias ExMCP.Tasks.Extension
    alias MCPJobs.ExMCP.Store
    alias MCPJobs.Task

    @handler_id "mcp-jobs-ex-mcp-notifications"
    @events [
      [:mcp_jobs, :task, :completed],
      [:mcp_jobs, :task, :failed],
      [:mcp_jobs, :task, :cancelled],
      [:mcp_jobs, :task, :progress]
    ]

    @spec attach() :: :ok | {:error, :already_exists}
    def attach, do: :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)

    @doc false
    def handle_event(_event, _measurements, %{task_id: task_id, oban: oban}, _config) do
      with {:ok, %Task{meta: %{"ex_mcp" => true}} = task} <- MCPJobs.get(task_id, oban: oban) do
        params = task |> Store.to_mcp_task() |> ExMCP.Tasks.Task.to_map(:modern)

        Subscriptions.publish_async(Extension.notification_method(), params, registry: registry())
      end

      :ok
    rescue
      exception ->
        Logger.error("MCPJobs could not notify ExMCP clients: " <> Exception.message(exception))
    end

    defp registry,
      do: Application.get_env(:mcp_jobs, :ex_mcp_subscription_registry, Subscriptions)
  end
end
