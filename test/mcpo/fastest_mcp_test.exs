defmodule MCPO.FastestMCPTest do
  use MCPO.DataCase

  alias MCPO.Task

  @tools [
    {MCPO.Test.SuccessWorker,
     name: "generate_report",
     description: "Generates a report.",
     input_schema: %{
       "type" => "object",
       "properties" => %{"value" => %{"type" => "integer"}},
       "required" => ["value"]
     }},
    {MCPO.Test.FailingWorker, name: "failing_report"},
    {MCPO.Test.UniqueWorker, name: "unique_report"},
    MCPO.Test.DocumentedWorker
  ]

  setup do
    name = "mcpo-test-#{System.unique_integer([:positive])}"

    server =
      name
      |> FastestMCP.server()
      |> MCPO.FastestMCP.add_tools(@tools, wait_timeout: 300)

    {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(name) end)

    %{name: name}
  end

  test "lists the workers as tools", %{name: name} do
    tools = name |> FastestMCP.list_tools() |> Map.new(&{&1.name, &1})

    assert %{
             description: "Generates a report.",
             input_schema: %{"required" => ["value"]},
             execution: %{taskSupport: "optional"}
           } = tools["generate_report"]

    assert %{description: "Builds a summary.", input_schema: %{"properties" => %{"text" => _}}} =
             tools["documented_worker"]
  end

  test "a call without a task waits for the job and returns its result", %{name: name} do
    stop_jobs = run_jobs_in_background()

    assert %{structuredContent: %{"value" => 4}} =
             FastestMCP.call_tool(name, "generate_report", %{"value" => 4})

    stop_jobs.()
    assert %Oban.Job{args: %{"value" => 4} = args} = Repo.one(Oban.Job)
    assert map_size(args) == 1
    assert %Task{status: :completed} = Repo.one(Task)
  end

  test "a task call uses the FastestMCP task ID and returns the result", %{name: name} do
    %FastestMCP.BackgroundTask{task_id: task_id} =
      task = FastestMCP.call_tool(name, "generate_report", %{"value" => 7}, task: true)

    eventually(fn -> Repo.get_by(Task, task_id: task_id) end)
    drain()

    assert %{structuredContent: %{"value" => 7}} = FastestMCP.await_task(task, 2_000)
    assert %Task{status: :completed} = Repo.get_by(Task, task_id: task_id)
  end

  @tag :unsandboxed
  test "cancelling the FastestMCP task cancels the MCPO task and its job", %{name: name} do
    %FastestMCP.BackgroundTask{task_id: task_id} =
      task = FastestMCP.call_tool(name, "generate_report", %{"value" => 8}, task: true)

    eventually(fn -> Repo.get_by(Task, task_id: task_id) end)
    FastestMCP.cancel_task(task)

    assert %Task{status: :cancelled, oban_job_id: job_id} =
             eventually(fn ->
               case Repo.get_by(Task, task_id: task_id) do
                 %Task{status: :cancelled} = cancelled -> cancelled
                 _other -> nil
               end
             end)

    assert %Oban.Job{state: "cancelled"} = Repo.get(Oban.Job, job_id)
  end

  test "a failed job returns an error result", %{name: name} do
    stop_jobs = run_jobs_in_background()

    assert %{isError: true, content: [%{"text" => text}]} =
             FastestMCP.call_tool(name, "failing_report", %{})

    stop_jobs.()
    assert text =~ "boom"
  end

  test "a job that does not finish in time is cancelled", %{name: name} do
    assert %{isError: true, content: [%{"text" => text}]} =
             FastestMCP.call_tool(name, "generate_report", %{"value" => 1})

    assert text =~ "did not finish in 300 ms"
    assert %Task{status: :cancelled} = Repo.one(Task)
    assert %Oban.Job{state: "cancelled"} = Repo.one(Oban.Job)
  end

  test "FastestMCP rejects arguments that do not match the schema", %{name: name} do
    assert_raise FastestMCP.Error, fn ->
      FastestMCP.call_tool(name, "generate_report", %{"value" => "five"})
    end

    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "a duplicate unique job returns an error result", %{name: name} do
    {:ok, _task} = MCPO.enqueue(MCPO.Test.UniqueWorker, %{"q" => 1})

    assert %{
             isError: true,
             content: [%{"text" => "A job with the same arguments already exists."}]
           } =
             FastestMCP.call_tool(name, "unique_report", %{"q" => 1})
  end
end
