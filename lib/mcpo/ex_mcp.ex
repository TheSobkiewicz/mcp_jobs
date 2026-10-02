if Code.ensure_loaded?(ExMCP.Tasks.Store) do
  defmodule MCPO.ExMCP do
    @moduledoc """
    Runs ExMCP tool calls as Oban jobs.

        defmodule MyApp.MCPServer do
          use MCPO.ExMCP

          @impl ExMCP.Server.Handler
          def handle_call_tool("generate_report", arguments, state) do
            create_task("generate_report", MyApp.Workers.GenerateReport, arguments, state)
          end
        end

    `use MCPO.ExMCP` is `use ExMCP.Server.Handler` with `MCPO.ExMCP.Store`
    as the task store. It also imports `create_task/4`. The client gets the task
    at once. ExMCP then answers `tasks/get` and `tasks/cancel` from the
    `mcpo_tasks` table.

    ## Options

    Other `ExMCP.Server.Handler` options are passed on. Put store options in
    `task_store_opts:`, for example `use MCPO.ExMCP, task_store_opts: [kill: true]`:

      * `:oban`: the Oban instance name.
      * `:job`: options for `c:Oban.Worker.new/2`.
      * `:kill`: when `true`, `tasks/cancel` also kills a running job.
      * `:ttl` and `:poll_interval`: in milliseconds, sent to the client.

    ## Limits

    The `input_required` status is not supported. MCPO does not publish
    `notifications/tasks`, so clients poll with `tasks/get`.
    """

    defmacro __using__(opts) do
      handler_opts = Keyword.merge([tasks: :store, task_store: MCPO.ExMCP.Store], opts)

      quote do
        use ExMCP.Server.Handler, unquote(handler_opts)

        import MCPO.ExMCP, only: [create_task: 4]
      end
    end

    @doc """
    Creates a task for `worker` in `c:ExMCP.Server.Handler.handle_call_tool/3`
    and returns the tool call result.
    """
    defmacro create_task(tool_name, worker, arguments, state) do
      quote do
        MCPO.ExMCP.create_task(
          unquote(tool_name),
          unquote(worker),
          unquote(arguments),
          unquote(state),
          __task_store_options__()
        )
      end
    end

    @doc """
    Creates a task for `worker`. `opts` are the task store options of the handler.

    Use it when the handler does not `use MCPO.ExMCP`.
    """
    @spec create_task(String.t(), module(), map(), term(), keyword()) ::
            {:ok, map(), term()} | {:error, term(), term()}
    def create_task(tool_name, worker, arguments, state, opts) do
      ExMCP.Tasks.Server.create(tool_name, arguments, state, [{:worker, worker} | opts])
    end
  end
end
