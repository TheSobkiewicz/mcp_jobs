if Code.ensure_loaded?(FastestMCP) do
  defmodule MCPJobs.FastestMCP do
    @moduledoc """
    Runs FastestMCP tool calls as Oban jobs.

    Add your Oban workers as tools:

        server =
          FastestMCP.server("reports")
          |> MCPJobs.FastestMCP.add_tools([
            MyApp.Workers.GenerateReport,
            {MyApp.Workers.SendEmail, description: "Sends an email."}
          ])

    The tool name, description and input schema follow the same rules as in
    `MCPJobs.ExMCP`: the options in the list, then `use MCPJobs.Tool`, then the Oban
    Pro `args_schema`, then the defaults. FastestMCP checks the arguments against
    the input schema.

    ## How a call runs

    Each tool call inserts an Oban job and waits for it. FastestMCP decides how
    the client gets the result:

      * A client with MCP Tasks (the 2025-11-25 version or the 2026-07-28
        extension) gets a FastestMCP task at once. The tool waits for the job in
        the background, without a time limit.
      * A client without tasks waits for the result. If the job does not finish
        in `:wait_timeout`, MCPJobs cancels it and returns an error result.

    A failed or cancelled job returns a tool result with `isError: true`.

    When a client cancels a FastestMCP task (`tasks/cancel`), FastestMCP stops
    the waiting tool process. MCPJobs then cancels the task and its job, as
    `MCPJobs.cancel/2` describes. When the tool process stops for another reason
    (the server stops, the client disconnects, or the wait fails), the job
    keeps running and the MCPJobs task finishes as usual.

    A failed task sends clients only the error `"message"`, see `MCPJobs`.

    ## Options

      * `:oban`: the Oban instance name.
      * `:job`: options for `c:Oban.Worker.new/2`.
      * `:kill`: when `true`, a cancel also kills a running job.
      * `:wait_timeout`: for clients without tasks, the maximum wait in
        milliseconds. The default is 9000.
      * `:interval`: the time between two status checks in milliseconds. The
        default is 1000 for tasks and 100 for clients without tasks.
      * `:task`: the FastestMCP task option of the tools. The default is
        `[mode: :optional]`.

    ## Limits

    FastestMCP keeps its tasks in memory by default. After a restart, a client
    cannot read a task that FastestMCP created before the restart, even though
    the Oban job and the MCPJobs task still exist.
    """

    alias FastestMCP.Tools.Result
    alias MCPJobs.Task

    @default_wait_timeout 9_000

    @doc "Adds one FastestMCP tool for each worker."
    @spec add_tools(FastestMCP.Server.t(), [module() | {module(), keyword()}], keyword()) ::
            FastestMCP.Server.t()
    def add_tools(server, tools, opts \\ []) do
      tools
      |> MCPJobs.ToolSpec.build()
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

      case MCPJobs.enqueue(worker, arguments, enqueue_opts) do
        {:ok, %Task{task_id: task_id}} ->
          if FastestMCP.Context.background_task?(ctx),
            do: cancel_on_task_cancel(self(), ctx, task_id, cancel_opts)

          [timeout: timeout, interval: _interval] = wait_opts = wait_opts(ctx, opts)

          on_progress = &send_progress(ctx, &1)

          case MCPJobs.await(task_id, [on_progress: on_progress] ++ wait_opts ++ oban_opts) do
            {:ok, task} -> tool_result(task)
            {:error, :timeout} -> timed_out(task_id, timeout, cancel_opts)
            {:error, :not_found} -> tool_error("The task was not found.")
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

    defp wait_opts(ctx, opts) do
      if FastestMCP.Context.background_task?(ctx),
        do: [timeout: :infinity, interval: Keyword.get(opts, :interval, 1_000)],
        else: [
          timeout: Keyword.get(opts, :wait_timeout, @default_wait_timeout),
          interval: Keyword.get(opts, :interval, 100)
        ]
    end

    # FastestMCP kills the tool process to cancel a task, and also when the
    # server stops. Only a real cancel cancels the job: FastestMCP marks the task
    # cancelled before the kill. The killed process cannot react, so a separate
    # process checks the FastestMCP task.
    defp cancel_on_task_cancel(tool_pid, ctx, task_id, cancel_opts) do
      spawn(fn ->
        ref = Process.monitor(tool_pid)

        receive do
          {:DOWN, ^ref, :process, ^tool_pid, :normal} ->
            :ok

          {:DOWN, ^ref, :process, ^tool_pid, _reason} ->
            if fastest_task_cancelled?(ctx, task_id), do: MCPJobs.cancel(task_id, cancel_opts)
        end
      end)
    end

    defp fastest_task_cancelled?(%FastestMCP.Context{server_name: server_name} = ctx, task_id) do
      match?(%{status: :cancelled}, FastestMCP.fetch_task(server_name, task_id, context: ctx))
    rescue
      _task_gone -> false
    catch
      :exit, _server_stopped -> false
    end

    # FastestMCP stores the progress in its task and sends it to the client.
    defp send_progress(ctx, %{"current" => current} = progress) do
      FastestMCP.Context.report_progress(
        ctx,
        current,
        Map.get(progress, "total"),
        Map.get(progress, "message")
      )
    end

    defp timed_out(task_id, timeout, cancel_opts) do
      case MCPJobs.__cancel_after_timeout__(task_id, cancel_opts) do
        {:cancelled, _task} ->
          tool_error("The task did not finish in #{timeout} ms and was cancelled.")

        {:finished, task} ->
          tool_result(task)

        {:error, :not_found} ->
          tool_error("The task was not found.")
      end
    end

    @doc false
    @spec __tool_result__(Task.t()) :: Result.t()
    def __tool_result__(task), do: tool_result(task)

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
      do: tool_error(MCPJobs.Status.error_message(error))

    defp tool_result(%Task{status: :cancelled}), do: tool_error("The task was cancelled.")

    defp tool_error(message),
      do: Result.new([%{"type" => "text", "text" => message}], is_error: true)
  end
end
