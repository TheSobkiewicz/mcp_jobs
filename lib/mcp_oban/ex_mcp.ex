if Code.ensure_loaded?(ExMCP.Tasks.Store) do
  defmodule MCPOban.ExMCP do
    @moduledoc """
    Runs ExMCP tool calls as Oban jobs.

    Configure the handler with `MCPOban.ExMCP.Store`, and create the task in
    `handle_call_tool/3`:

        defmodule MyApp.MCPServer do
          use ExMCP.Server.Handler, tasks: :store, task_store: MCPOban.ExMCP.Store

          @impl ExMCP.Server.Handler
          def handle_call_tool("generate_report", arguments, state) do
            MCPOban.ExMCP.create_task(
              "generate_report",
              MyApp.Workers.GenerateReport,
              arguments,
              state,
              __task_store_options__()
            )
          end
        end

    The client gets the task at once. ExMCP then answers `tasks/get` and
    `tasks/cancel` from the `mcp_oban_tasks` table.

    ## Options

    Put these in `task_store_opts:` of the handler, or in the last argument:

      * `:oban`: the Oban instance name.
      * `:job`: options for `c:Oban.Worker.new/2`.
      * `:kill`: when `true`, `tasks/cancel` also kills a running job.
      * `:ttl` and `:poll_interval`: in milliseconds, sent to the client.

    ## Limits

    The `input_required` status is not supported. MCPOban does not publish
    `notifications/tasks`, so clients poll with `tasks/get`.
    """

    @doc "Creates a task for `worker` and returns the ExMCP tool call result."
    @spec create_task(String.t(), module(), map(), term(), keyword()) ::
            {:ok, map(), term()} | {:error, term(), term()}
    def create_task(tool_name, worker, arguments, state, opts \\ []) do
      ExMCP.Tasks.Server.create(tool_name, arguments, state, [{:worker, worker} | opts])
    end
  end
end
