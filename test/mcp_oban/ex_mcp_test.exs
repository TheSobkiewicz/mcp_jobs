defmodule MCPOban.ExMCPTest do
  use MCPOban.DataCase

  alias ExMCP.Tasks
  alias ExMCP.Tasks.Extension
  alias MCPOban.Test.{FailingWorker, SuccessWorker}

  @owner %{principal_id: "user-1", tenant_id: "tenant-1", audience: "mcp"}
  @other_owner %{principal_id: "user-2", tenant_id: "tenant-1", audience: "mcp"}

  defp opts(extra \\ []) do
    [store: MCPOban.ExMCP.Store, owner: @owner, notify: false] ++ extra
  end

  defp create(worker, arguments) do
    {:ok, %{"taskId" => task_id} = created} =
      Tasks.create("generate_report", arguments, opts(worker: worker, ttl: 60_000))

    {task_id, created}
  end

  test "create returns a valid working task and inserts its job" do
    {task_id, created} = create(SuccessWorker, %{"value" => 1})

    assert %{"status" => "working", "resultType" => "task", "ttlMs" => 60_000} = created
    assert :ok = Extension.validate_task_result(created, :create)
    assert_enqueued(worker: SuccessWorker, args: %{"value" => 1}, meta: %{mcp_task_id: task_id})
  end

  test "get returns the result as a tool call result when the job succeeds" do
    {task_id, _created} = create(SuccessWorker, %{"value" => 7})
    drain()

    assert {:ok, %{"status" => "completed", "result" => result} = task} =
             Tasks.get(task_id, opts())

    assert :ok = Extension.validate_task_result(task, :detailed)

    assert %{
             "structuredContent" => %{"value" => 7},
             "content" => [%{"type" => "text", "text" => text}]
           } = result

    assert JSON.decode!(text) == %{"value" => 7}
  end

  test "get returns a JSON-RPC error when the job is discarded" do
    {task_id, _created} = create(FailingWorker, %{})
    drain()

    assert {:ok, %{"status" => "failed", "error" => error} = task} = Tasks.get(task_id, opts())

    assert error == %{"code" => -32_603, "message" => "The task failed."}
    refute inspect(task) =~ "boom"
  end

  test "cancel cancels the task and its job" do
    {task_id, _created} = create(SuccessWorker, %{"value" => 1})

    assert :ok = Tasks.cancel(task_id, opts())
    assert {:ok, %{"status" => "cancelled"}} = Tasks.get(task_id, opts())
    assert {:ok, true} = Tasks.cancellation_requested?(task_id, opts())
    assert %Oban.Job{state: "cancelled"} = Repo.one(Oban.Job)
  end

  test "cancel leaves a running job alone, and kills it with the kill option" do
    {task_id, _created} = create(SuccessWorker, %{"value" => 1})
    {other_id, _created} = create(SuccessWorker, %{"value" => 2})
    Repo.update_all(Oban.Job, set: [state: "executing"])

    assert :ok = Tasks.cancel(task_id, opts())
    assert :ok = Tasks.cancel(other_id, opts(kill: true))

    states = Repo.all(from(j in Oban.Job, order_by: j.id, select: j.state))
    assert states == ["executing", "cancelled"]
  end

  test "cancel of a terminal task is acknowledged and changes nothing" do
    {task_id, _created} = create(SuccessWorker, %{"value" => 1})
    drain()

    assert :ok = Tasks.cancel(task_id, opts())
    assert {:ok, %{"status" => "completed"}} = Tasks.get(task_id, opts())
  end

  test "another owner cannot read or cancel the task" do
    {task_id, _created} = create(SuccessWorker, %{"value" => 1})
    other = Keyword.put(opts(), :owner, @other_owner)

    assert {:error, :not_found_or_unauthorized} = Tasks.get(task_id, other)
    assert {:error, :not_found_or_unauthorized} = Tasks.cancel(task_id, other)
    assert {:ok, %{"status" => "working"}} = Tasks.get(task_id, opts())
  end

  test "another owner cannot take over a task ID" do
    {task_id, _created} = create(SuccessWorker, %{"value" => 1})

    other = [store: MCPOban.ExMCP.Store, owner: @other_owner, notify: false]

    assert {:error, :already_exists} =
             Tasks.create("generate_report", %{}, [id: task_id, worker: SuccessWorker] ++ other)

    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "worker transitions go through the store" do
    {task_id, _created} = create(SuccessWorker, %{"value" => 1})

    assert {:ok, %ExMCP.Tasks.Task{state: :completed}} =
             Tasks.complete(task_id, %{"content" => []}, opts())

    assert {:error, :invalid_transition} = Tasks.fail(task_id, %{"message" => "late"}, opts())
    assert {:error, :invalid_transition} = Tasks.put_status_message(task_id, "hi", opts())
  end

  test "an owner with atom values can create and read a task" do
    atom_owner = [
      store: MCPOban.ExMCP.Store,
      owner: %{principal_id: :alice, tenant_id: "t", audience: "mcp"},
      notify: false
    ]

    assert {:ok, %{"taskId" => task_id}} =
             Tasks.create(
               "generate_report",
               %{"value" => 1},
               [worker: SuccessWorker] ++ atom_owner
             )

    assert {:ok, %{"status" => "working"}} = Tasks.get(task_id, atom_owner)
  end

  test "get shows the progress of a working task as its status message" do
    {task_id, _created} = create(SuccessWorker, %{"value" => 1})
    %MCPOban.Task{oban_job_id: job_id} = Repo.get_by(MCPOban.Task, task_id: task_id)
    job = %{Repo.get(Oban.Job, job_id) | conf: Oban.config()}

    :ok = MCPOban.progress(job, 2, 5, "Rendering")

    assert {:ok, %{"status" => "working", "statusMessage" => "Rendering (2/5)"}} =
             Tasks.get(task_id, opts())
  end

  test "create without a worker is rejected" do
    assert {:error, :invalid_task} = Tasks.create("generate_report", %{}, opts())
  end
end
