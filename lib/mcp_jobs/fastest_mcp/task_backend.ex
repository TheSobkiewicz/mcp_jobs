if Code.ensure_loaded?(FastestMCP) do
  defmodule MCPJobs.FastestMCP.TaskBackend do
    @moduledoc """
    A FastestMCP task backend that keeps FastestMCP tasks in PostgreSQL, so they
    survive a restart.

        FastestMCP.start_server(server,
          task_backend: {MCPJobs.FastestMCP.TaskBackend, oban: Oban}
        )

    It needs the `mcp_jobs_fastest_tasks` table (`MCPJobs.Migration` version 3).

    ## After a restart

    FastestMCP marks every unfinished task as failed when it starts, because the
    process that ran it is gone. For a task of an `MCPJobs.FastestMCP` tool, the
    Oban job is not gone. This backend keeps such a task `working`, and when
    FastestMCP reads it, the backend shows the state of the MCPJobs task:

      * working, with its progress
      * completed, with the result
      * failed or cancelled

    A client can also cancel such a task: the backend then cancels the MCPJobs
    task and its job.

    ## Options

      * `:oban`: the Oban instance name.
      * `:kill`: when `true`, a cancel after a restart also kills a running job.

    The task data is stored in the Erlang term format. Only this backend writes
    and reads it.
    """

    @behaviour FastestMCP.TaskBackend

    import Ecto.Query

    alias FastestMCP.Error
    alias FastestMCP.ResultNormalizer
    alias MCPJobs.Task
    alias Oban.Repo

    @table "mcp_jobs_fastest_tasks"
    @modern_protocol "2026-07-28"

    @impl FastestMCP.TaskBackend
    def start_link(opts \\ []), do: Agent.start_link(fn -> Keyword.take(opts, [:oban, :kill]) end)

    @impl FastestMCP.TaskBackend
    def put_task(store, task) do
      opts = Agent.get(store, & &1)
      conf = MCPJobs.__config__(opts)
      task = keep_restarted_task_working(conf, task)

      cancel_mcp_task(task, opts)
      write(conf, task)
    rescue
      exception -> {:error, exception}
    end

    @impl FastestMCP.TaskBackend
    def fetch_task(store, task_id, opts \\ []) do
      backend_opts = Agent.get(store, & &1)
      conf = MCPJobs.__config__(backend_opts)
      query = from(t in @table, where: t.task_id == ^to_string(task_id), select: t.data)

      with data when is_binary(data) <- Repo.one(conf, query),
           task = decode(data),
           true <- visible?(task, opts) do
        {:ok, with_mcp_state(conf, task, backend_opts)}
      else
        _missing_or_hidden -> {:error, :not_found}
      end
    end

    @impl FastestMCP.TaskBackend
    def delete_task(store, task_id) do
      conf = store |> Agent.get(& &1) |> MCPJobs.__config__()
      Repo.delete_all(conf, from(t in @table, where: t.task_id == ^to_string(task_id)))

      :ok
    end

    @impl FastestMCP.TaskBackend
    def list_tasks(store, opts \\ []) do
      backend_opts = Agent.get(store, & &1)
      conf = MCPJobs.__config__(backend_opts)
      session_id = opts |> Keyword.get(:session_id) |> to_string_or_nil()
      owner = owner_filter(opts)
      page_size = Keyword.get(opts, :page_size)
      after_key = decode_cursor(Keyword.get(opts, :cursor), session_id, owner)

      rows =
        from(t in @table,
          select: %{task_id: t.task_id, submitted_at: t.submitted_at, data: t.data},
          order_by: [desc: t.submitted_at, asc: t.task_id]
        )
        |> filter_session(session_id)
        |> filter_owner(owner)
        |> after_cursor(after_key)
        |> limit_page(page_size)
        |> then(&Repo.all(conf, &1))

      {page, next_cursor} = paginate(rows, page_size, session_id, owner)

      tasks =
        Enum.map(page, fn %{data: data} -> with_mcp_state(conf, decode(data), backend_opts) end)

      {:ok, %{tasks: tasks, next_cursor: next_cursor}}
    rescue
      error in Error -> {:error, error}
    end

    @impl FastestMCP.TaskBackend
    def expire_tasks(store, now_ms) do
      conf = store |> Agent.get(& &1) |> MCPJobs.__config__()
      query = from(t in @table, where: t.expires_at <= ^now_ms, select: t.task_id)
      {_count, task_ids} = Repo.delete_all(conf, query)

      {:ok, task_ids}
    end

    # When FastestMCP restarts, it marks running tasks as failed. The Oban job of
    # an MCPJobs task keeps running, so the task stays working.
    defp keep_restarted_task_working(
           conf,
           %{id: task_id, status: :failed, error: %Error{code: :runtime_restarted}} = task
         ) do
      case MCPJobs.Repository.get(conf, to_string(task_id)) do
        %Task{} ->
          Map.merge(task, %{
            status: :working,
            error: nil,
            failure_message: nil,
            terminal_outcome: nil,
            completed_at: nil,
            expires_at: nil,
            pid: nil,
            monitor_ref: nil
          })

        nil ->
          task
      end
    end

    defp keep_restarted_task_working(_conf, task), do: task

    # After a restart, no watcher process exists to cancel the job.
    defp cancel_mcp_task(%{id: task_id, status: :cancelled}, opts),
      do: MCPJobs.cancel(to_string(task_id), opts)

    defp cancel_mcp_task(_task, _opts), do: :ok

    # A working task without a process is a task from before a restart.
    defp with_mcp_state(conf, %{id: task_id, status: :working, pid: nil} = task, opts) do
      case MCPJobs.get(to_string(task_id), opts) do
        {:ok, %Task{status: :working, progress: progress}} ->
          Map.put(task, :progress, fastest_progress(progress))

        {:ok, %Task{} = finished} ->
          task = finished(task, finished)
          write(conf, task)
          task

        {:error, :not_found} ->
          task
      end
    end

    defp with_mcp_state(_conf, task, _opts), do: task

    defp fastest_progress(nil), do: nil

    defp fastest_progress(%{"current" => current} = progress) do
      %{
        current: current,
        total: Map.get(progress, "total"),
        message: Map.get(progress, "message")
      }
    end

    defp finished(%{ttl_ms: ttl_ms} = task, %Task{status: status} = mcp_task) do
      now = System.system_time(:millisecond)

      task
      |> Map.merge(%{completed_at: now, updated_at: now, expires_at: now + ttl_ms})
      |> Map.merge(outcome(task, status, mcp_task))
    end

    defp outcome(_task, :cancelled, _mcp_task) do
      %{
        status: :cancelled,
        error: %Error{code: :cancelled, message: "background task was cancelled"},
        failure_message: "Task cancelled",
        terminal_outcome: :cancelled
      }
    end

    defp outcome(task, status, mcp_task) do
      result =
        mcp_task |> MCPJobs.FastestMCP.__tool_result__() |> ResultNormalizer.normalize_tool()

      case status do
        :completed ->
          %{status: :completed, result: result, terminal_outcome: :success_result}

        :failed ->
          %{
            status: tool_error_status(task),
            result: result,
            terminal_outcome: :tool_error_result,
            failure_message: MCPJobs.Status.error_message(mcp_task_error(mcp_task))
          }
      end
    end

    # FastestMCP reports a tool error as completed on the modern protocol and as
    # failed on the older one.
    defp tool_error_status(%{protocol_version: @modern_protocol}), do: :completed
    defp tool_error_status(_task), do: :failed

    defp mcp_task_error(%Task{error: error}), do: error

    defp write(conf, task) do
      %{id: task_id, session_id: session_id, submitted_at: submitted_at} = task

      row = %{
        task_id: to_string(task_id),
        session_id: to_string_or_nil(session_id),
        owner_fingerprint: task |> Map.get(:owner_fingerprint) |> to_string_or_nil(),
        submitted_at: submitted_at,
        expires_at: Map.get(task, :expires_at),
        data: :erlang.term_to_binary(task)
      }

      Repo.insert_all(conf, @table, [row],
        on_conflict: {:replace, [:session_id, :owner_fingerprint, :expires_at, :data]},
        conflict_target: :task_id
      )

      :ok
    end

    defp decode(data), do: :erlang.binary_to_term(data)

    defp visible?(task, opts) do
      session_ok? =
        case Keyword.get(opts, :session_id) do
          nil -> true
          session_id -> to_string_or_nil(Map.get(task, :session_id)) == to_string(session_id)
        end

      owner_ok? =
        case owner_filter(opts) do
          :any -> true
          owner -> to_string_or_nil(Map.get(task, :owner_fingerprint)) == owner
        end

      session_ok? and owner_ok?
    end

    defp owner_filter(opts) do
      if Keyword.has_key?(opts, :owner_fingerprint),
        do: opts |> Keyword.get(:owner_fingerprint) |> to_string_or_nil(),
        else: :any
    end

    defp filter_session(query, nil), do: query
    defp filter_session(query, session_id), do: where(query, [t], t.session_id == ^session_id)

    defp filter_owner(query, :any), do: query
    defp filter_owner(query, nil), do: where(query, [t], is_nil(t.owner_fingerprint))
    defp filter_owner(query, owner), do: where(query, [t], t.owner_fingerprint == ^owner)

    defp after_cursor(query, nil), do: query

    defp after_cursor(query, {submitted_at, task_id}) do
      where(
        query,
        [t],
        t.submitted_at < ^submitted_at or
          (t.submitted_at == ^submitted_at and t.task_id > ^task_id)
      )
    end

    defp limit_page(query, nil), do: query

    defp limit_page(query, page_size) when is_integer(page_size) and page_size > 0,
      do: limit(query, ^(page_size + 1))

    defp limit_page(_query, _page_size),
      do: raise(Error, code: :bad_request, message: "page_size must be a positive integer")

    defp paginate(rows, nil, _session_id, _owner), do: {rows, nil}

    defp paginate(rows, page_size, session_id, owner) do
      case Enum.split(rows, page_size) do
        {page, []} ->
          {page, nil}

        {page, _more} ->
          %{submitted_at: submitted_at, task_id: task_id} = List.last(page)
          {page, encode_cursor(session_id, owner, submitted_at, task_id)}
      end
    end

    defp encode_cursor(session_id, owner, submitted_at, task_id) do
      %{
        "sessionId" => session_id,
        "ownerFingerprint" => owner_for_cursor(owner),
        "after" => [submitted_at, task_id]
      }
      |> JSON.encode!()
      |> Base.url_encode64(padding: false)
    end

    defp decode_cursor(nil, _session_id, _owner), do: nil

    defp decode_cursor(cursor, session_id, owner) when is_binary(cursor) do
      expected_owner = owner_for_cursor(owner)

      with {:ok, json} <- Base.url_decode64(cursor, padding: false),
           {:ok,
            %{
              "sessionId" => ^session_id,
              "ownerFingerprint" => ^expected_owner,
              "after" => [submitted_at, task_id]
            }}
           when is_integer(submitted_at) and is_binary(task_id) <- JSON.decode(json) do
        {submitted_at, task_id}
      else
        _invalid -> raise Error, code: :bad_request, message: "invalid cursor"
      end
    end

    defp decode_cursor(_cursor, _session_id, _owner),
      do: raise(Error, code: :bad_request, message: "invalid cursor")

    defp owner_for_cursor(:any), do: "*"
    defp owner_for_cursor(owner), do: owner

    defp to_string_or_nil(nil), do: nil
    defp to_string_or_nil(value), do: to_string(value)
  end
end
