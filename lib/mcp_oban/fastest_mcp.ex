if Code.ensure_loaded?(FastestMCP) do
  defmodule MCPOban.FastestMCP do
    @moduledoc """
    Runs FastestMCP tool calls as Oban jobs.

    Add your Oban workers as tools:

        server =
          FastestMCP.server("reports")
          |> MCPOban.FastestMCP.add_tools([
            MyApp.Workers.GenerateReport,
            {MyApp.Workers.SendEmail, description: "Sends an email."}
          ])

    The tool name, description and input schema follow the same rules as in
    `MCPOban.ExMCP`: the options in the list, then `use MCPOban.Tool`, then the Oban
    Pro `args_schema`, then the defaults. FastestMCP checks the arguments against
    the input schema.

    ## How a call runs

    Each tool call inserts an Oban job and waits for it. FastestMCP decides how
    the client gets the result:

      * A client with MCP Tasks (the 2025-11-25 version or the 2026-07-28
        extension) gets a FastestMCP task at once. The tool waits for the job in
        the background, without a time limit.
      * A client without tasks waits for the result. If the job does not finish
        in `:wait_timeout`, MCPOban cancels it and returns an error result.

    A failed or cancelled job returns a tool result with `isError: true`.

    When FastestMCP cancels a task (`tasks/cancel`, or the task expires), it
    stops the waiting tool process. MCPOban then cancels the task and its job, as
    `MCPOban.cancel/2` describes.

    ## Options

      * `:oban`: the Oban instance name.
      * `:job`: options for `c:Oban.Worker.new/2`.
      * `:kill`: when `true`, a cancel also kills a running job.
      * `:wait_timeout`: for clients without tasks, the maximum wait in
        milliseconds. The default is 9000.
      * `:task`: the FastestMCP task option of the tools. The default is
        `[mode: :optional]`.

    ## Limits

    FastestMCP keeps its tasks in memory by default. After a restart, a client
    cannot read a task that FastestMCP created before the restart, even though
    the Oban job and the MCPOban task still exist.
    """

    alias FastestMCP.Tools.Result
    alias MCPOban.Task

    @default_wait_timeout 9_000

    @doc "Adds one FastestMCP tool for each worker."
    @spec add_tools(FastestMCP.Server.t(), [module() | {module(), keyword()}], keyword()) ::
            FastestMCP.Server.t()
    def add_tools(server, tools, opts \\ []) do
      tools
      |> MCPOban.ToolSpec.build()
      |> Enum.reduce(server, &add_tool(&2, &1, opts))
    end

    defp add_tool(server, %{name: name, worker: worker} = spec, opts) do
      %{description: description, input_schema: input_schema} = spec

      FastestMCP.add_tool(
        server,
        name,
        fn arguments, ctx -> __call__(name, worker, arguments, ctx, opts) end,
        description: description,
        input_schema: input_schema,
        task: Keyword.get(opts, :task, mode: :optional)
      )
    end

    @doc false
    @spec __call__(String.t(), module(), map(), FastestMCP.Context.t(), keyword()) ::
            Result.t()
    def __call__(tool_name, worker, arguments, ctx, opts) do
      oban_opts = Keyword.take(opts, [:oban])
      cancel_opts = Keyword.take(opts, [:oban, :kill])

      enqueue_opts =
        [meta: %{"tool_name" => tool_name}, job: Keyword.get(opts, :job, [])] ++
          task_id_opts(ctx) ++ oban_opts

      case MCPOban.enqueue(worker, arguments, enqueue_opts) do
        {:ok, %Task{task_id: task_id}} ->
          cancel_when_stopped(self(), task_id, cancel_opts)
          timeout = wait_timeout(ctx, opts)

          case MCPOban.await(task_id, [timeout: timeout] ++ oban_opts) do
            {:ok, task} -> tool_result(task)
            {:error, :timeout} -> timed_out(task_id, timeout, cancel_opts)
          end

        {:error, :job_conflict} ->
          tool_error("A job with the same arguments already exists.")

        {:error, _reason} ->
          tool_error("The task could not be started.")
      end
    end

    defp task_id_opts(ctx) do
      case FastestMCP.Context.task_id(ctx) do
        nil -> []
        task_id -> [task_id: to_string(task_id)]
      end
    end

    defp wait_timeout(ctx, opts) do
      if FastestMCP.Context.background_task?(ctx),
        do: :infinity,
        else: Keyword.get(opts, :wait_timeout, @default_wait_timeout)
    end

    # FastestMCP stops the tool process to cancel a task. The process cannot
    # react to that itself, so a separate process cancels the MCPOban task.
    defp cancel_when_stopped(tool_pid, task_id, cancel_opts) do
      spawn(fn ->
        ref = Process.monitor(tool_pid)

        receive do
          {:DOWN, ^ref, :process, ^tool_pid, :normal} -> :ok
          {:DOWN, ^ref, :process, ^tool_pid, _reason} -> MCPOban.cancel(task_id, cancel_opts)
        end
      end)
    end

    defp timed_out(task_id, timeout, cancel_opts) do
      case MCPOban.__cancel_after_timeout__(task_id, cancel_opts) do
        {:cancelled, _task} ->
          tool_error("The task did not finish in #{timeout} ms and was cancelled.")

        {:finished, task} ->
          tool_result(task)

        {:error, :not_found} ->
          tool_error("The task was not found.")
      end
    end

    defp tool_result(%Task{status: :completed, result: nil}), do: Result.new([])

    defp tool_result(%Task{status: :completed, result: %{"content" => content} = result})
         when is_list(content) do
      case result do
        %{"structuredContent" => structured} ->
          Result.new(content, structured_content: structured)

        _content_only ->
          Result.new(content)
      end
    end

    defp tool_result(%Task{status: :completed, result: result}),
      do: Result.new(nil, structured_content: result)

    defp tool_result(%Task{status: :failed, error: error}),
      do: tool_error(MCPOban.Status.error_message(error))

    defp tool_result(%Task{status: :cancelled}), do: tool_error("The task was cancelled.")

    defp tool_error(message),
      do: Result.new([%{"type" => "text", "text" => message}], is_error: true)
  end
end
