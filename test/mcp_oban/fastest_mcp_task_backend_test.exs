defmodule MCPOban.FastestMCP.TaskBackendTest do
  use MCPOban.DataCase

  alias MCPOban.FastestMCP.TaskBackend
  alias MCPOban.Task

  @moduletag :unsandboxed

  @tools [{MCPOban.Test.SuccessWorker, name: "generate_report"}]

  setup do
    name = "mcp-oban-durable-#{System.unique_integer([:positive])}"
    start_server(name)

    on_exit(fn ->
      FastestMCP.stop_server(name)
      Repo.query!("DELETE FROM mcp_oban_fastest_tasks")
    end)

    %{name: name}
  end

  defp start_server(name) do
    server = name |> FastestMCP.server() |> MCPOban.FastestMCP.add_tools(@tools, interval: 20)
    {:ok, _pid} = FastestMCP.start_server(server, task_backend: {TaskBackend, oban: Oban})
  end

  defp restart(name) do
    :ok = FastestMCP.stop_server(name)
    start_server(name)
  end

  defp start_task(name, value) do
    %FastestMCP.BackgroundTask{task_id: task_id} =
      FastestMCP.call_tool(name, "generate_report", %{"value" => value}, task: true)

    eventually(fn -> Repo.get_by(Task, task_id: task_id) end)
    task_id
  end

  defp fetch(name, task_id), do: FastestMCP.fetch_task(name, task_id)

  test "keeps FastestMCP tasks in the database", %{name: name} do
    task_id = start_task(name, 1)

    assert %{rows: [[1]]} =
             Repo.query!("SELECT count(*) FROM mcp_oban_fastest_tasks WHERE task_id = $1", [
               task_id
             ])

    drain()

    assert %{status: :completed, result: %{structuredContent: %{"value" => 1}}} =
             eventually(fn ->
               case fetch(name, task_id) do
                 %{status: :completed} = task -> task
                 _working -> nil
               end
             end)
  end

  test "builds the same result as FastestMCP after a restart", %{name: name} do
    task_id = start_task(name, 5)
    drain()

    %{result: from_fastest_mcp} =
      eventually(fn ->
        case fetch(name, task_id) do
          %{status: :completed} = task -> task
          _working -> nil
        end
      end)

    {:ok, mcp_task} = MCPOban.get(task_id)

    from_backend =
      mcp_task
      |> MCPOban.FastestMCP.__tool_result__()
      |> FastestMCP.ResultNormalizer.normalize_tool()

    assert from_backend == from_fastest_mcp
  end

  test "a task that runs during a restart stays working and then completes", %{name: name} do
    task_id = start_task(name, 7)

    restart(name)

    assert %{status: :working} = fetch(name, task_id)

    drain()

    assert %{status: :completed, result: %{structuredContent: %{"value" => 7}}} =
             fetch(name, task_id)
  end

  test "the progress of a restarted task reaches FastestMCP", %{name: name} do
    task_id = start_task(name, 2)
    restart(name)

    %Task{oban_job_id: job_id} = Repo.get_by(Task, task_id: task_id)
    :ok = MCPOban.progress(%{Repo.get(Oban.Job, job_id) | conf: Oban.config()}, 1, 3, "Loading")

    assert %{status: :working, progress: %{current: 1, total: 3, message: "Loading"}} =
             fetch(name, task_id)
  end

  test "cancelling a restarted task cancels the job", %{name: name} do
    task_id = start_task(name, 3)
    restart(name)

    FastestMCP.cancel_task(name, task_id)

    assert %Task{status: :cancelled, oban_job_id: job_id} = Repo.get_by(Task, task_id: task_id)
    assert %Oban.Job{state: "cancelled"} = Repo.get(Oban.Job, job_id)
  end

  test "lists tasks in pages, newest first", %{name: name} do
    ids = for value <- 1..3, do: start_task(name, value)

    assert %{tasks: first_page, next_cursor: cursor} = FastestMCP.list_tasks(name, page_size: 2)
    assert is_binary(cursor)

    assert %{tasks: second_page, next_cursor: nil} =
             FastestMCP.list_tasks(name, page_size: 2, cursor: cursor)

    listed = Enum.map(first_page ++ second_page, & &1.id)
    assert Enum.sort(listed) == Enum.sort(ids)
    assert length(Enum.uniq(listed)) == 3

    assert_raise FastestMCP.Error, fn ->
      FastestMCP.list_tasks(name, page_size: 2, cursor: "not-a-cursor")
    end
  end
end
