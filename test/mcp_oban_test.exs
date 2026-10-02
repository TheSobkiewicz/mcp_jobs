defmodule MCPObanTest do
  use MCPOban.DataCase

  alias MCPOban.Task

  alias MCPOban.Test.{
    CancelledDuringRunWorker,
    CrashingWorker,
    FailingWorker,
    FlakyWorker,
    PlainWorker,
    SuccessWorker,
    ValueWorker
  }

  describe "enqueue/3" do
    test "creates a working task and inserts its job" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id, status: :working}} =
        MCPOban.enqueue(SuccessWorker, %{value: 1})

      assert_enqueued(worker: SuccessWorker, args: %{value: 1}, meta: %{mcp_task_id: task_id})
      assert %Oban.Job{id: ^job_id} = Repo.one(Oban.Job)
    end

    test "uses the given task ID and passes job options" do
      {:ok, %Task{task_id: "abc"}} =
        MCPOban.enqueue(SuccessWorker, %{value: 1}, task_id: "abc", job: [priority: 3])

      assert_enqueued(worker: SuccessWorker, priority: 3, meta: %{mcp_task_id: "abc"})
    end

    test "makes random task IDs" do
      {:ok, %Task{task_id: first}} = MCPOban.enqueue(SuccessWorker, %{value: 1})
      {:ok, %Task{task_id: second}} = MCPOban.enqueue(SuccessWorker, %{value: 1})

      assert first != second
      assert byte_size(first) >= 22
    end

    test "returns the existing task and inserts no job for a duplicate task ID" do
      {:ok, %Task{id: id}} = MCPOban.enqueue(SuccessWorker, %{value: 1}, task_id: "dup")
      {:ok, %Task{id: ^id}} = MCPOban.enqueue(SuccessWorker, %{value: 2}, task_id: "dup")

      assert [%Oban.Job{args: %{"value" => 1}}] = Repo.all(Oban.Job)
    end

    test "inserts one job when the same task ID is sent at the same time" do
      results =
        1..10
        |> Enum.map(fn _ ->
          Elixir.Task.async(fn ->
            MCPOban.enqueue(SuccessWorker, %{value: 1}, task_id: "same")
          end)
        end)
        |> Elixir.Task.await_many()

      assert Enum.all?(results, &match?({:ok, %Task{task_id: "same"}}, &1))
      assert Repo.aggregate(Oban.Job, :count) == 1
      assert Repo.aggregate(Task, :count) == 1
    end
  end

  describe "successful job" do
    test "completes the task and saves the result" do
      attach_telemetry()
      {:ok, %Task{task_id: task_id}} = MCPOban.enqueue(SuccessWorker, %{value: 42})

      assert {:ok, %{status: :working}} = MCPOban.status(task_id)
      assert %{success: 1} = drain()
      assert {:ok, %{status: :completed, result: %{"value" => 42}}} = MCPOban.status(task_id)

      assert_received {:telemetry, [:mcp_oban, :task, :started], %{system_time: _},
                       %{task_id: ^task_id, worker: "MCPOban.Test.SuccessWorker"}}

      assert_received {:telemetry, [:mcp_oban, :task, :completed], %{duration: duration},
                       %{task_id: ^task_id, oban_job_id: job_id}}

      assert is_integer(duration) and is_integer(job_id)
    end

    test "saves the result in the task when perform/1 returns it" do
      {:ok, %Task{task_id: task_id}} = MCPOban.enqueue(SuccessWorker, %{value: 3})

      drain()

      assert %Task{status: :completed, result: %{"value" => 3}} =
               Repo.get_by(Task, task_id: task_id)
    end

    test "wraps a result that is not a map" do
      {:ok, %Task{task_id: task_id}} = MCPOban.enqueue(ValueWorker, %{})

      drain()

      assert {:ok, %{status: :completed, result: %{"value" => "done"}}} = MCPOban.status(task_id)
    end

    test "completes the task without a result when perform/1 returns :ok" do
      {:ok, %Task{task_id: task_id}} = MCPOban.enqueue(PlainWorker, %{})

      drain()

      assert %Task{status: :completed, result: nil} = Repo.get_by(Task, task_id: task_id)
    end
  end

  describe "retry" do
    test "keeps the task working between attempts, then completes it" do
      attach_telemetry()
      {:ok, %Task{task_id: task_id}} = MCPOban.enqueue(FlakyWorker, %{succeed_on: 3})

      assert %{failure: 1} = Oban.drain_queue(queue: :default)
      assert {:ok, %{status: :working}} = MCPOban.status(task_id)

      assert %{failure: 1} = Oban.drain_queue(queue: :default, with_scheduled: true)
      assert {:ok, %{status: :working}} = MCPOban.status(task_id)

      assert %{success: 1} = Oban.drain_queue(queue: :default, with_scheduled: true)
      assert {:ok, %{status: :completed, result: %{"attempt" => 3}}} = MCPOban.status(task_id)

      refute_received {:telemetry, [:mcp_oban, :task, :failed], _, _}
    end
  end

  describe "permanent failure" do
    test "fails the task when Oban discards the job" do
      attach_telemetry()
      {:ok, %Task{task_id: task_id}} = MCPOban.enqueue(FailingWorker, %{})

      assert %{failure: 1, discard: 1} = drain()
      assert %Task{status: :failed} = Repo.get_by(Task, task_id: task_id)
      assert {:ok, %{status: :failed, error: %{"message" => message}}} = MCPOban.status(task_id)
      assert message =~ "boom"

      assert_received {:telemetry, [:mcp_oban, :task, :failed], _, %{task_id: ^task_id}}
    end

    test "fails the task when the worker raises" do
      {:ok, %Task{task_id: task_id}} = MCPOban.enqueue(CrashingWorker, %{})

      drain()

      assert {:ok, %{status: :failed, error: %{"message" => "crash"}}} = MCPOban.status(task_id)
    end
  end

  describe "cancel/2" do
    test "cancels the task and its waiting job" do
      attach_telemetry()

      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPOban.enqueue(SuccessWorker, %{value: 1})

      assert {:ok, %Task{status: :cancelled}} = MCPOban.cancel(task_id)
      assert {:ok, %{status: :cancelled}} = MCPOban.status(task_id)
      assert %Oban.Job{state: "cancelled"} = Repo.get(Oban.Job, job_id)

      assert_received {:telemetry, [:mcp_oban, :task, :cancelled], _, %{task_id: ^task_id}}
    end

    test "does not cancel a running job, and the worker does not save its result" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPOban.enqueue(SuccessWorker, %{value: 1})

      Repo.update_all(where(Oban.Job, id: ^job_id), set: [state: "executing"])

      {:ok, _task} = MCPOban.cancel(task_id)

      assert %Oban.Job{state: "executing"} = Repo.get(Oban.Job, job_id)

      Repo.update_all(where(Oban.Job, id: ^job_id), set: [state: "available"])
      assert %{success: 1} = drain()

      assert {:ok, %Task{status: :cancelled, result: nil}} = MCPOban.get(task_id)
    end

    test "kills a running job with the kill option" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPOban.enqueue(SuccessWorker, %{value: 1})

      Repo.update_all(where(Oban.Job, id: ^job_id), set: [state: "executing"])

      {:ok, _task} = MCPOban.cancel(task_id, kill: true)

      assert %Oban.Job{state: "cancelled"} = Repo.get(Oban.Job, job_id)
    end

    test "lets a running worker see the cancel and stop" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPOban.enqueue(CancelledDuringRunWorker, %{})

      assert %{cancelled: 1} = drain()
      assert {:ok, %Task{status: :cancelled, result: nil}} = MCPOban.get(task_id)
      assert %Oban.Job{state: "cancelled"} = Repo.get(Oban.Job, job_id)
    end

    test "returns an error for a terminal or unknown task" do
      {:ok, %Task{task_id: task_id}} = MCPOban.enqueue(SuccessWorker, %{value: 1})
      drain()

      assert {:error, :terminal} = MCPOban.cancel(task_id)
      assert {:error, :not_found} = MCPOban.cancel("missing")
      assert {:ok, %{status: :completed}} = MCPOban.status(task_id)
    end
  end

  describe "status/2" do
    test "returns not found for an unknown task" do
      assert {:error, :not_found} = MCPOban.status("missing")
    end

    test "fails a working task when its job is discarded without an event" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPOban.enqueue(SuccessWorker, %{value: 1})

      Repo.update_all(where(Oban.Job, id: ^job_id),
        set: [state: "discarded", errors: [%{"attempt" => 1, "at" => "now", "error" => "lost"}]]
      )

      assert {:ok, %{status: :failed, error: %{"message" => "lost"}}} = MCPOban.status(task_id)
    end

    test "cancels a working task when its job is deleted" do
      {:ok, %Task{task_id: task_id}} = MCPOban.enqueue(SuccessWorker, %{value: 1})
      Repo.delete_all(Oban.Job)

      assert {:ok, %{status: :cancelled}} = MCPOban.status(task_id)
    end
  end

  describe "races" do
    test "a cancel after completion does nothing" do
      {:ok, %Task{task_id: task_id}} = MCPOban.enqueue(SuccessWorker, %{value: 1})
      drain()

      assert {:error, :terminal} = MCPOban.cancel(task_id)
      assert {:ok, %{status: :completed}} = MCPOban.status(task_id)
    end

    test "a discard after cancel keeps the task cancelled" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} = MCPOban.enqueue(FailingWorker, %{})
      Repo.update_all(where(Oban.Job, id: ^job_id), set: [state: "executing"])
      {:ok, _task} = MCPOban.cancel(task_id)

      conf = Oban.config()
      assert :noop = MCPOban.transition(conf, task_id, :failed, error: %{"message" => "late"})
      assert {:ok, %Task{status: :cancelled, error: nil}} = MCPOban.get(task_id)
    end

    test "one change wins when complete, fail and cancel run at the same time" do
      {:ok, %Task{task_id: task_id}} = MCPOban.enqueue(SuccessWorker, %{value: 1})
      conf = Oban.config()

      results =
        [
          fn -> MCPOban.transition(conf, task_id, :completed, result: %{"value" => 1}) end,
          fn -> MCPOban.transition(conf, task_id, :failed, error: %{"message" => "x"}) end,
          fn -> MCPOban.cancel(task_id) end
        ]
        |> Enum.map(&Elixir.Task.async/1)
        |> Elixir.Task.await_many()

      winners = Enum.count(results, &match?({:ok, _task}, &1))

      assert winners == 1
      assert {:ok, %Task{status: status}} = MCPOban.get(task_id)
      assert status in [:completed, :failed, :cancelled]
    end
  end

  describe "MCPOban.Cleaner" do
    test "deletes old terminal tasks and keeps working tasks" do
      {:ok, %Task{task_id: done}} = MCPOban.enqueue(SuccessWorker, %{value: 1})
      {:ok, %Task{task_id: running}} = MCPOban.enqueue(FlakyWorker, %{succeed_on: 3})
      drain_once = Oban.drain_queue(queue: :default)
      assert %{success: 1, failure: 1} = drain_once

      old = DateTime.add(DateTime.utc_now(), -2, :day)
      Repo.update_all(Task, set: [updated_at: old])

      assert {:ok, 1} = perform_job(MCPOban.Cleaner, %{})
      assert {:error, :not_found} = MCPOban.status(done)
      assert {:ok, %{status: :working}} = MCPOban.status(running)
    end
  end
end
