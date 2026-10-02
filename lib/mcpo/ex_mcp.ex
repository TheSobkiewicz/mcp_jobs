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

    ## Clients without tasks

    A client that does not declare the MCP Tasks extension cannot poll a task.
    For these clients, `create_task/4` waits for the Oban job and returns the
    tool result directly. A failed or cancelled job returns a result with
    `"isError" => true`. If the job does not finish in `:wait_timeout`, the task
    is cancelled and the result is an error.

    While it waits, the tool call is blocked:

      * Over HTTP, ExMCP stops a handler call after `:handler_call_timeout`
        (10 seconds by default). Keep `:wait_timeout` lower, or raise
        `:handler_call_timeout` on `ExMCP.HttpPlug`.
      * Over stdio, other requests on the same connection wait.

    Declare the tool with `"execution" => %{"taskSupport" => "optional"}`, so
    that clients with and without tasks can call it.

    ## Options

    Other `ExMCP.Server.Handler` options are passed on. Put store options in
    `task_store_opts:`, for example `use MCPO.ExMCP, task_store_opts: [kill: true]`:

      * `:oban`: the Oban instance name.
      * `:job`: options for `c:Oban.Worker.new/2`.
      * `:kill`: when `true`, `tasks/cancel` also kills a running job.
      * `:ttl` and `:poll_interval`: in milliseconds, sent to the client.
      * `:wait_timeout`: for clients without tasks, the maximum wait in
        milliseconds. The default is 9000.

    ## Limits

    The `input_required` status is not supported. MCPO does not publish
    `notifications/tasks`, so clients poll with `tasks/get`.
    """

    alias ExMCP.Tasks.Extension
    alias MCPO.ExMCP.Store
    alias MCPO.Task

    @default_wait_timeout 9_000

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
      if tasks_declared?() do
        ExMCP.Tasks.Server.create(tool_name, arguments, state, [{:worker, worker} | opts])
      else
        {:ok, run_and_wait(tool_name, worker, arguments, opts), state}
      end
    end

    defp tasks_declared? do
      case ExMCP.Server.Context.current() do
        %{era: :modern, client_capabilities: capabilities} -> Extension.declared?(capabilities)
        _legacy_or_outside_request -> false
      end
    end

    defp run_and_wait(tool_name, worker, arguments, opts) do
      oban_opts = Keyword.take(opts, [:oban])
      timeout = Keyword.get(opts, :wait_timeout, @default_wait_timeout)

      enqueue_opts = [
        owner: Store.normalize_owner(ExMCP.Tasks.owner(opts)),
        meta: %{"tool_name" => tool_name},
        job: Keyword.get(opts, :job, [])
      ]

      with {:ok, %Task{task_id: task_id}} <-
             MCPO.enqueue(worker, arguments, enqueue_opts ++ oban_opts) do
        case MCPO.await(task_id, [timeout: timeout] ++ oban_opts) do
          {:ok, %Task{status: :completed} = task} ->
            Store.call_tool_result(task)

          {:ok, %Task{status: :failed, error: error}} ->
            tool_error(Store.error_message(error))

          {:ok, %Task{status: :cancelled}} ->
            tool_error("The task was cancelled.")

          {:error, :timeout} ->
            MCPO.cancel(task_id, oban_opts)
            tool_error("The task did not finish in #{timeout} ms and was cancelled.")
        end
      else
        {:error, _reason} -> tool_error("The task could not be started.")
      end
    end

    defp tool_error(message) do
      %{"content" => [%{"type" => "text", "text" => message}], "isError" => true}
    end
  end
end
