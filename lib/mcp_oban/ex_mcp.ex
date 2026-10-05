if Code.ensure_loaded?(ExMCP.Tasks.Store) do
  defmodule MCPOban.ExMCP do
    @moduledoc """
    Runs ExMCP tool calls as Oban jobs.

    List your Oban workers as tools:

        defmodule MyApp.MCPServer do
          use MCPOban.ExMCP,
            tools: [
              MyApp.Workers.GenerateReport,
              {MyApp.Workers.SendEmail,
               description: "Sends an email.",
               input_schema: %{
                 "type" => "object",
                 "properties" => %{"to" => %{"type" => "string"}},
                 "required" => ["to"]
               }}
            ]
        end

    Each call of a tool inserts a job for its worker. The client gets the task
    at once. ExMCP then answers `tasks/get` and `tasks/cancel` from the
    `mcp_oban_tasks` table.

    ## Tool options

      * `:name`: the tool name. The default is made from the last part of the
        module name: `MyApp.Workers.SendEmail` becomes `"send_email"`.
      * `:description`: the tool description.
      * `:input_schema`: the JSON Schema of the tool arguments. The default
        accepts any object. The arguments become the job args.

    MCPOban checks the arguments against the input schema before it inserts a job.
    Invalid arguments return a tool result with `"isError" => true`, and no job
    starts. An invalid schema raises at compile time.

    A worker with `use MCPOban.Tool` gives its own name, description (from
    `@moduledoc`) and input schema. The options in the `tools:` list override them.

    An Oban Pro worker with `args_schema` gets its input schema from it: field
    types, `required: true`, defaults, enum values, and embedded fields. Unknown
    keys are not allowed, as in Oban Pro. An `:input_schema` option overrides it.

    ## Generated callbacks

    `use MCPOban.ExMCP` is `use ExMCP.Server.Handler` with `MCPOban.ExMCP.Store` as
    the task store. It defines `handle_initialize/2`, `handle_list_tools/2` and
    `handle_call_tool/3` for the listed tools. You can define them again, and
    call `super/3` for the MCPOban tools:

        def handle_call_tool("echo", %{"text" => text}, state),
          do: {:ok, %{"content" => [%{"type" => "text", "text" => text}]}, state}

        def handle_call_tool(name, arguments, state), do: super(name, arguments, state)

    For a tool that is not in the list, call `create_task/4` from your own
    `handle_call_tool/3`.

    Set `server_info: %{"name" => ..., "version" => ...}` to change the server
    name that `initialize` returns.

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

    Listed tools have `"execution" => %{"taskSupport" => "optional"}`, so that
    clients with and without tasks can call them.

    ## Options

    Other `ExMCP.Server.Handler` options are passed on. Put store options in
    `task_store_opts:`, for example `use MCPOban.ExMCP, task_store_opts: [kill: true]`:

      * `:oban`: the Oban instance name.
      * `:job`: options for `c:Oban.Worker.new/2`.
      * `:kill`: when `true`, `tasks/cancel` also kills a running job.
      * `:ttl` and `:poll_interval`: in milliseconds, sent to the client.
      * `:wait_timeout`: for clients without tasks, the maximum wait in
        milliseconds. The default is 9000.
      * `:interval`: for clients without tasks, the time between two status
        checks in milliseconds. The default is 100.

    A failed task sends clients only the error `"message"`, see `MCPOban`.

    ## Limits

    The `input_required` status is not supported. MCPOban does not publish
    `notifications/tasks`, so clients poll with `tasks/get`.
    """

    alias ExMCP.Content.SchemaValidator
    alias ExMCP.Tasks.Extension
    alias MCPOban.ExMCP.Store
    alias MCPOban.Task

    @default_wait_timeout 9_000
    @legacy_versions ~w(2025-11-25 2025-06-18 2025-03-26 2024-11-05)

    defmacro __using__(opts) do
      {tools, opts} = Keyword.pop(opts, :tools, [])
      {server_info, opts} = Keyword.pop(opts, :server_info)
      handler_opts = Keyword.merge([tasks: :store, task_store: MCPOban.ExMCP.Store], opts)

      quote do
        use ExMCP.Server.Handler, unquote(handler_opts)

        import MCPOban.ExMCP, only: [create_task: 4]

        @mcp_oban_tools MCPOban.ExMCP.__tools__(unquote(tools))
        @mcp_oban_server_info unquote(server_info) ||
                                %{"name" => inspect(__MODULE__), "version" => "1.0.0"}

        @impl ExMCP.Server.Handler
        def handle_initialize(params, state),
          do: {:ok, MCPOban.ExMCP.__initialize__(params, @mcp_oban_server_info), state}

        @impl ExMCP.Server.Handler
        def handle_list_tools(_cursor, state),
          do: {:ok, MCPOban.ExMCP.__list_tools__(@mcp_oban_tools), nil, state}

        @impl ExMCP.Server.Handler
        def handle_call_tool(name, arguments, state) do
          MCPOban.ExMCP.__call_tool__(
            @mcp_oban_tools,
            name,
            arguments,
            state,
            __task_store_options__()
          )
        end

        defoverridable handle_initialize: 2, handle_list_tools: 2, handle_call_tool: 3
      end
    end

    @doc false
    @spec __tools__([module() | {module(), keyword()}]) :: [map()]
    def __tools__(tools) do
      specs = MCPOban.ToolSpec.build(tools)
      Enum.each(specs, &check_schema!/1)
      specs
    end

    @doc false
    @spec __initialize__(map(), map()) :: map()
    def __initialize__(params, server_info) do
      version =
        case params do
          %{"protocolVersion" => version} when version in @legacy_versions -> version
          _other -> hd(@legacy_versions)
        end

      %{
        "protocolVersion" => version,
        "serverInfo" => server_info,
        "capabilities" => %{"tools" => %{}}
      }
    end

    @doc false
    @spec __list_tools__([map()]) :: [map()]
    def __list_tools__(specs) do
      for %{name: name, description: description, input_schema: input_schema} <- specs do
        %{
          "name" => name,
          "description" => description,
          "inputSchema" => input_schema,
          "execution" => %{"taskSupport" => "optional"}
        }
      end
    end

    @doc false
    @spec __call_tool__([map()], String.t(), map(), term(), keyword()) ::
            {:ok, map(), term()} | {:error, term(), term()}
    def __call_tool__(specs, name, arguments, state, opts) do
      arguments = tool_arguments(arguments)

      case Enum.find(specs, &match?(%{name: ^name}, &1)) do
        %{worker: worker, input_schema: schema} ->
          case SchemaValidator.validate_schema(arguments, schema) do
            :ok -> create_task(name, worker, arguments, state, opts)
            {:error, errors} -> {:ok, tool_error(invalid_arguments(errors)), state}
          end

        nil ->
          {:error, "Unknown tool: #{name}", state}
      end
    end

    defp invalid_arguments(errors) do
      details =
        Enum.map_join(errors, "; ", fn
          %{field: field, message: message} when field in [nil, ""] -> message
          %{field: field, message: message} -> "#{field}: #{message}"
        end)

      "Invalid arguments: " <> details
    end

    defp check_schema!(%{worker: worker, input_schema: input_schema}) do
      case SchemaValidator.compile_schema(input_schema) do
        {:ok, _compiled} ->
          :ok

        {:error, reason} ->
          raise ArgumentError, "invalid input schema for #{inspect(worker)}: #{inspect(reason)}"
      end
    end

    @doc """
    Creates a task for `worker` in `c:ExMCP.Server.Handler.handle_call_tool/3`
    and returns the tool call result.
    """
    defmacro create_task(tool_name, worker, arguments, state) do
      quote do
        MCPOban.ExMCP.create_task(
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

    Use it when the handler does not `use MCPOban.ExMCP`.
    """
    @spec create_task(String.t(), module(), map(), term(), keyword()) ::
            {:ok, map(), term()} | {:error, term(), term()}
    def create_task(tool_name, worker, arguments, state, opts) do
      arguments = tool_arguments(arguments)

      if tasks_declared?() do
        ExMCP.Tasks.Server.create(tool_name, arguments, state, [{:worker, worker} | opts])
      else
        {:ok, run_and_wait(tool_name, worker, arguments, opts), state}
      end
    end

    # ExMCP adds the request id and the request _meta to the tool arguments.
    # They are not tool arguments and must not become job args.
    defp tool_arguments(arguments), do: Map.drop(arguments, ["_request_id", "_meta"])

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
             MCPOban.enqueue(worker, arguments, enqueue_opts ++ oban_opts) do
        wait_opts = [timeout: timeout, interval: Keyword.get(opts, :interval, 100)]

        case MCPOban.await(task_id, wait_opts ++ oban_opts) do
          {:ok, task} ->
            tool_result(task)

          {:error, :timeout} ->
            __timed_out__(task_id, timeout, opts)
        end
      else
        {:error, :job_conflict} -> tool_error("A job with the same arguments already exists.")
        {:error, _reason} -> tool_error("The task could not be started.")
      end
    end

    @doc false
    @spec __timed_out__(String.t(), non_neg_integer(), keyword()) :: map()
    def __timed_out__(task_id, timeout, opts) do
      case MCPOban.__cancel_after_timeout__(task_id, Keyword.take(opts, [:oban, :kill])) do
        {:cancelled, _task} ->
          tool_error("The task did not finish in #{timeout} ms and was cancelled.")

        {:finished, task} ->
          tool_result(task)

        {:error, :not_found} ->
          tool_error("The task was not found.")
      end
    end

    defp tool_result(%Task{status: :completed} = task), do: Store.call_tool_result(task)

    defp tool_result(%Task{status: :failed, error: error}),
      do: tool_error(MCPOban.Status.error_message(error))

    defp tool_result(%Task{status: :cancelled}), do: tool_error("The task was cancelled.")

    defp tool_error(message) do
      %{"content" => [%{"type" => "text", "text" => message}], "isError" => true}
    end
  end
end
