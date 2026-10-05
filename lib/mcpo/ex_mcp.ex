if Code.ensure_loaded?(ExMCP.Tasks.Store) do
  defmodule MCPO.ExMCP do
    @moduledoc """
    Runs ExMCP tool calls as Oban jobs.

    List your Oban workers as tools:

        defmodule MyApp.MCPServer do
          use MCPO.ExMCP,
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
    `mcpo_tasks` table.

    ## Tool options

      * `:name`: the tool name. The default is made from the last part of the
        module name: `MyApp.Workers.SendEmail` becomes `"send_email"`.
      * `:description`: the tool description.
      * `:input_schema`: the JSON Schema of the tool arguments. The default
        accepts any object. The arguments become the job args.

    MCPO checks the arguments against the input schema before it inserts a job.
    Invalid arguments return a tool result with `"isError" => true`, and no job
    starts. An invalid schema raises at compile time.

    A worker with `use MCPO.Tool` gives its own name, description (from
    `@moduledoc`) and input schema. The options in the `tools:` list override them.

    An Oban Pro worker with `args_schema` gets its input schema from it: field
    types, `required: true`, defaults, enum values, and embedded fields. Unknown
    keys are not allowed, as in Oban Pro. An `:input_schema` option overrides it.

    ## Generated callbacks

    `use MCPO.ExMCP` is `use ExMCP.Server.Handler` with `MCPO.ExMCP.Store` as
    the task store. It defines `handle_initialize/2`, `handle_list_tools/2` and
    `handle_call_tool/3` for the listed tools. You can define them again, and
    call `super/3` for the MCPO tools:

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

    alias ExMCP.Content.SchemaValidator
    alias ExMCP.Tasks.Extension
    alias MCPO.ExMCP.Store
    alias MCPO.Task

    @default_wait_timeout 9_000
    @legacy_versions ~w(2025-11-25 2025-06-18 2025-03-26 2024-11-05)

    defmacro __using__(opts) do
      {tools, opts} = Keyword.pop(opts, :tools, [])
      {server_info, opts} = Keyword.pop(opts, :server_info)
      handler_opts = Keyword.merge([tasks: :store, task_store: MCPO.ExMCP.Store], opts)

      quote do
        use ExMCP.Server.Handler, unquote(handler_opts)

        import MCPO.ExMCP, only: [create_task: 4]

        @mcpo_tools MCPO.ExMCP.__tools__(unquote(tools))
        @mcpo_server_info unquote(server_info) ||
                            %{"name" => inspect(__MODULE__), "version" => "1.0.0"}

        @impl ExMCP.Server.Handler
        def handle_initialize(params, state),
          do: {:ok, MCPO.ExMCP.__initialize__(params, @mcpo_server_info), state}

        @impl ExMCP.Server.Handler
        def handle_list_tools(_cursor, state),
          do: {:ok, MCPO.ExMCP.__list_tools__(@mcpo_tools), nil, state}

        @impl ExMCP.Server.Handler
        def handle_call_tool(name, arguments, state) do
          MCPO.ExMCP.__call_tool__(@mcpo_tools, name, arguments, state, __task_store_options__())
        end

        defoverridable handle_initialize: 2, handle_list_tools: 2, handle_call_tool: 3
      end
    end

    @doc false
    @spec __tools__([module() | {module(), keyword()}]) :: [map()]
    def __tools__(tools) do
      specs = Enum.map(tools, &tool_spec/1)
      names = Enum.map(specs, fn %{name: name} -> name end)

      case names -- Enum.uniq(names) do
        [] -> specs
        duplicates -> raise ArgumentError, "duplicate MCPO tool names: #{inspect(duplicates)}"
      end
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

    defp tool_spec(worker) when is_atom(worker), do: tool_spec({worker, []})

    defp tool_spec({worker, opts}) when is_atom(worker) and is_list(opts) do
      Code.ensure_compiled!(worker)

      if not function_exported?(worker, :perform, 1) do
        raise ArgumentError, "#{inspect(worker)} is not an Oban worker"
      end

      opts = Keyword.merge(MCPO.Tool.options(worker), opts)

      input_schema =
        Keyword.get_lazy(opts, :input_schema, fn ->
          MCPO.ArgsSchema.from_worker(worker) || %{"type" => "object"}
        end)

      case SchemaValidator.compile_schema(input_schema) do
        {:ok, _compiled} ->
          :ok

        {:error, reason} ->
          raise ArgumentError, "invalid input schema for #{inspect(worker)}: #{inspect(reason)}"
      end

      %{
        name: Keyword.get_lazy(opts, :name, fn -> default_name(worker) end),
        worker: worker,
        description:
          Keyword.get(opts, :description, "Runs #{inspect(worker)} as a background job."),
        input_schema: input_schema
      }
    end

    defp default_name(worker) do
      worker
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
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
      oban_opts = Keyword.take(opts, [:oban])

      case MCPO.cancel(task_id, Keyword.take(opts, [:oban, :kill])) do
        {:ok, _task} ->
          tool_error("The task did not finish in #{timeout} ms and was cancelled.")

        {:error, :terminal} ->
          case MCPO.get(task_id, oban_opts) do
            {:ok, task} -> tool_result(task)
            {:error, :not_found} -> tool_error("The task was not found.")
          end

        {:error, :not_found} ->
          tool_error("The task was not found.")
      end
    end

    defp tool_result(%Task{status: :completed} = task), do: Store.call_tool_result(task)

    defp tool_result(%Task{status: :failed, error: error}),
      do: tool_error(Store.error_message(error))

    defp tool_result(%Task{status: :cancelled}), do: tool_error("The task was cancelled.")

    defp tool_error(message) do
      %{"content" => [%{"type" => "text", "text" => message}], "isError" => true}
    end
  end
end
