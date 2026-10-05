defmodule MCPJobsTest do
  use MCPJobs.DataCase

  alias MCPJobs.Task

  alias MCPJobs.Test.{
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
        MCPJobs.enqueue(SuccessWorker, %{value: 1})

      assert_enqueued(worker: SuccessWorker, args: %{value: 1}, meta: %{mcp_task_id: task_id})
      assert %Oban.Job{id: ^job_id} = Repo.one(Oban.Job)
    end

    test "uses the given task ID and passes job options" do
      {:ok, %Task{task_id: "abc"}} =
        MCPJobs.enqueue(SuccessWorker, %{value: 1}, task_id: "abc", job: [priority: 3])

      assert_enqueued(worker: SuccessWorker, priority: 3, meta: %{mcp_task_id: "abc"})
    end

    test "makes random task IDs" do
      {:ok, %Task{task_id: first}} = MCPJobs.enqueue(SuccessWorker, %{value: 1})
      {:ok, %Task{task_id: second}} = MCPJobs.enqueue(SuccessWorker, %{value: 1})

      assert first != second
      assert byte_size(first) >= 22
    end

    test "returns the existing task and inserts no job for a duplicate task ID" do
      {:ok, %Task{id: id}} = MCPJobs.enqueue(SuccessWorker, %{value: 1}, task_id: "dup")
      {:ok, %Task{id: ^id}} = MCPJobs.enqueue(SuccessWorker, %{value: 2}, task_id: "dup")

      assert [%Oban.Job{args: %{"value" => 1}}] = Repo.all(Oban.Job)
    end

    test "inserts one job when the same task ID is sent at the same time" do
      results =
        1..10
        |> Enum.map(fn _ ->
          Elixir.Task.async(fn ->
            MCPJobs.enqueue(SuccessWorker, %{value: 1}, task_id: "same")
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
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(SuccessWorker, %{value: 42})

      assert {:ok, %{status: :working}} = MCPJobs.status(task_id)
      assert %{success: 1} = drain()
      assert {:ok, %{status: :completed, result: %{"value" => 42}}} = MCPJobs.status(task_id)

      assert_received {:telemetry, [:mcp_jobs, :task, :started], %{system_time: _},
                       %{task_id: ^task_id, worker: "MCPJobs.Test.SuccessWorker", oban: Oban}}

      assert_received {:telemetry, [:mcp_jobs, :task, :completed], %{duration: duration},
                       %{task_id: ^task_id, oban_job_id: job_id}}

      assert is_integer(duration) and is_integer(job_id)
    end

    test "saves the result in the task when perform/1 returns it" do
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(SuccessWorker, %{value: 3})

      drain()

      assert %Task{status: :completed, result: %{"value" => 3}} =
               Repo.get_by(Task, task_id: task_id)
    end

    test "wraps a result that is not a map" do
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(ValueWorker, %{})

      drain()

      assert {:ok, %{status: :completed, result: %{"value" => "done"}}} = MCPJobs.status(task_id)
    end

    test "completes the task without a result when perform/1 returns :ok" do
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(PlainWorker, %{})

      drain()

      assert %Task{status: :completed, result: nil} = Repo.get_by(Task, task_id: task_id)
    end
  end

  describe "retry" do
    test "keeps the task working between attempts, then completes it" do
      attach_telemetry()
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(FlakyWorker, %{succeed_on: 3})

      assert %{failure: 1} = Oban.drain_queue(queue: :default)
      assert {:ok, %{status: :working}} = MCPJobs.status(task_id)

      assert %{failure: 1} = Oban.drain_queue(queue: :default, with_scheduled: true)
      assert {:ok, %{status: :working}} = MCPJobs.status(task_id)

      assert %{success: 1} = Oban.drain_queue(queue: :default, with_scheduled: true)
      assert {:ok, %{status: :completed, result: %{"attempt" => 3}}} = MCPJobs.status(task_id)

      refute_received {:telemetry, [:mcp_jobs, :task, :failed], _, _}
    end
  end

  describe "permanent failure" do
    test "fails the task when Oban discards the job" do
      attach_telemetry()
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(FailingWorker, %{})

      assert %{failure: 1, discard: 1} = drain()
      assert %Task{status: :failed} = Repo.get_by(Task, task_id: task_id)

      assert {:ok,
              %{status: :failed, error: %{"message" => "The task failed.", "details" => details}}} =
               MCPJobs.status(task_id)

      assert details =~ "boom"

      assert_received {:telemetry, [:mcp_jobs, :task, :failed], _, %{task_id: ^task_id}}
    end

    test "fails the task when the worker raises" do
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(CrashingWorker, %{})

      drain()

      assert {:ok,
              %{status: :failed, error: %{"message" => "The task failed.", "details" => "crash"}}} =
               MCPJobs.status(task_id)
    end
  end

  describe "cancel/2" do
    test "cancels the task and its waiting job" do
      attach_telemetry()

      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPJobs.enqueue(SuccessWorker, %{value: 1})

      assert {:ok, %Task{status: :cancelled}} = MCPJobs.cancel(task_id)
      assert {:ok, %{status: :cancelled}} = MCPJobs.status(task_id)
      assert %Oban.Job{state: "cancelled"} = Repo.get(Oban.Job, job_id)

      assert_received {:telemetry, [:mcp_jobs, :task, :cancelled], _, %{task_id: ^task_id}}
    end

    test "does not cancel a running job, and the worker does not save its result" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPJobs.enqueue(SuccessWorker, %{value: 1})

      Repo.update_all(where(Oban.Job, id: ^job_id), set: [state: "executing"])

      {:ok, _task} = MCPJobs.cancel(task_id)

      assert %Oban.Job{state: "executing"} = Repo.get(Oban.Job, job_id)

      Repo.update_all(where(Oban.Job, id: ^job_id), set: [state: "available"])
      assert %{success: 1} = drain()

      assert {:ok, %Task{status: :cancelled, result: nil}} = MCPJobs.get(task_id)
    end

    test "kills a running job with the kill option" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPJobs.enqueue(SuccessWorker, %{value: 1})

      Repo.update_all(where(Oban.Job, id: ^job_id), set: [state: "executing"])

      {:ok, _task} = MCPJobs.cancel(task_id, kill: true)

      assert %Oban.Job{state: "cancelled"} = Repo.get(Oban.Job, job_id)
    end

    test "lets a running worker see the cancel and stop" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPJobs.enqueue(CancelledDuringRunWorker, %{})

      assert %{cancelled: 1} = drain()
      assert {:ok, %Task{status: :cancelled, result: nil}} = MCPJobs.get(task_id)
      assert %Oban.Job{state: "cancelled"} = Repo.get(Oban.Job, job_id)
    end

    test "returns an error for a terminal or unknown task" do
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(SuccessWorker, %{value: 1})
      drain()

      assert {:error, :terminal} = MCPJobs.cancel(task_id)
      assert {:error, :not_found} = MCPJobs.cancel("missing")
      assert {:ok, %{status: :completed}} = MCPJobs.status(task_id)
    end
  end

  describe "await/2" do
    test "returns the task when it is done" do
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(SuccessWorker, %{value: 1})
      drain()

      assert {:ok, %Task{status: :completed}} = MCPJobs.await(task_id)
    end

    test "returns a timeout for a working task and does not cancel it" do
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(SuccessWorker, %{value: 1})

      assert {:error, :timeout} = MCPJobs.await(task_id, timeout: 50, interval: 10)
      assert {:ok, %{status: :working}} = MCPJobs.status(task_id)
      assert {:error, :not_found} = MCPJobs.await("missing")
    end
  end

  describe "status/2" do
    test "returns not found for an unknown task" do
      assert {:error, :not_found} = MCPJobs.status("missing")
    end

    test "fails a working task when its job is discarded without an event" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPJobs.enqueue(SuccessWorker, %{value: 1})

      Repo.update_all(where(Oban.Job, id: ^job_id),
        set: [state: "discarded", errors: [%{"attempt" => 1, "at" => "now", "error" => "lost"}]]
      )

      assert {:ok,
              %{status: :failed, error: %{"message" => "The task failed.", "details" => "lost"}}} =
               MCPJobs.status(task_id)
    end

    test "cancels a working task when its job is deleted" do
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(SuccessWorker, %{value: 1})
      Repo.delete_all(Oban.Job)

      assert {:ok, %{status: :cancelled}} = MCPJobs.status(task_id)
    end
  end

  describe "review fixes" do
    test "a read between the job ack and the telemetry event does not lose the result" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPJobs.enqueue(SuccessWorker, %{value: 1})

      Repo.update_all(where(Oban.Job, id: ^job_id),
        set: [state: "completed", completed_at: DateTime.utc_now()]
      )

      assert {:ok, %{status: :working}} = MCPJobs.status(task_id)

      job = Repo.get(Oban.Job, job_id)

      MCPJobs.Telemetry.handle_event(
        [:oban, :job, :stop],
        %{},
        %{job: job, state: :success, conf: Oban.config(), result: {:ok, %{"value" => 1}}},
        nil
      )

      assert {:ok, %{status: :completed, result: %{"value" => 1}}} = MCPJobs.status(task_id)
    end

    test "a completed job without a saved result completes the task after the grace period" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPJobs.enqueue(SuccessWorker, %{value: 1})

      Repo.update_all(where(Oban.Job, id: ^job_id),
        set: [state: "completed", completed_at: DateTime.add(DateTime.utc_now(), -10, :second)]
      )

      assert {:ok, %{status: :completed, result: nil}} = MCPJobs.status(task_id)
    end

    test "a duplicate unique job is rejected and no task is saved" do
      assert {:ok, %Task{}} =
               MCPJobs.enqueue(MCPJobs.Test.UniqueWorker, %{q: 1}, owner: %{"u" => 1})

      assert {:error, :job_conflict} =
               MCPJobs.enqueue(MCPJobs.Test.UniqueWorker, %{q: 1}, owner: %{"u" => 2})

      assert Repo.aggregate(Task, :count) == 1
      assert Repo.aggregate(Oban.Job, :count) == 1
    end

    test "a result that cannot be saved as JSON fails the task" do
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(MCPJobs.Test.TupleWorker, %{})

      drain()

      assert %Task{status: :failed, error: %{"message" => message}} =
               Repo.get_by(Task, task_id: task_id)

      assert message == "The result could not be saved as JSON."
    end

    test "a result with a NUL character fails the task" do
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(MCPJobs.Test.NulWorker, %{})

      drain()

      assert %Task{
               status: :failed,
               error: %{"message" => "The result could not be saved as JSON."}
             } =
               Repo.get_by(Task, task_id: task_id)
    end

    test "a database error while saving the result leaves the task working" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPJobs.enqueue(SuccessWorker, %{value: 1})

      conf = %{Oban.config() | repo: MCPJobs.Test.FlakyRepo}

      MCPJobs.Telemetry.handle_event(
        [:oban, :job, :stop],
        %{},
        %{
          job: Repo.get(Oban.Job, job_id),
          state: :success,
          conf: conf,
          result: {:ok, %{"v" => 1}}
        },
        nil
      )

      assert %Task{status: :working} = Repo.get_by(Task, task_id: task_id)
    end

    test "enqueue works with Oban in inline testing mode" do
      start_supervised!({Oban, name: MCPJobs.Test.InlineOban, repo: Repo, testing: :inline})

      assert {:ok, %Task{task_id: task_id}} =
               MCPJobs.enqueue(SuccessWorker, %{value: 5}, oban: MCPJobs.Test.InlineOban)

      assert {:ok, %{status: :completed, result: %{"value" => 5}}} =
               MCPJobs.status(task_id, oban: MCPJobs.Test.InlineOban)
    end

    test "a suspended job is working and can be cancelled" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPJobs.enqueue(SuccessWorker, %{value: 1}, job: [state: "suspended"])

      assert {:ok, %{status: :working}} = MCPJobs.status(task_id)
      assert {:ok, %Task{status: :cancelled}} = MCPJobs.cancel(task_id)
      assert %Oban.Job{state: "cancelled"} = Repo.get(Oban.Job, job_id)
    end
  end

  describe "open findings" do
    test "an existing task_id with another owner or worker is not returned" do
      {:ok, %Task{id: id}} =
        MCPJobs.enqueue(SuccessWorker, %{value: 1}, task_id: "1", owner: %{user: 1})

      assert {:error, :already_exists} =
               MCPJobs.enqueue(SuccessWorker, %{value: 1}, task_id: "1", owner: %{user: 2})

      assert {:error, :already_exists} =
               MCPJobs.enqueue(PlainWorker, %{}, task_id: "1", owner: %{user: 1})

      assert {:ok, %Task{id: ^id}} =
               MCPJobs.enqueue(SuccessWorker, %{value: 1}, task_id: "1", owner: %{"user" => 1})

      assert Repo.aggregate(Oban.Job, :count) == 1
    end

    test "a failed attempt of a cancelled task does not run again" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPJobs.enqueue(FlakyWorker, %{succeed_on: 3})

      Repo.update_all(where(Oban.Job, id: ^job_id), set: [state: "executing"])
      {:ok, _task} = MCPJobs.cancel(task_id)
      Repo.update_all(where(Oban.Job, id: ^job_id), set: [state: "available"])

      assert %{failure: 1} = Oban.drain_queue(queue: :default)
      assert %Oban.Job{state: "cancelled", attempt: 1} = Repo.get(Oban.Job, job_id)

      assert %{success: 0, failure: 0} =
               Oban.drain_queue(queue: :default, with_scheduled: true, with_recursion: true)

      assert {:ok, %{status: :cancelled}} = MCPJobs.status(task_id)
    end

    test "a result with a content key that is not a list is wrapped" do
      task = %Task{status: :completed, result: %{"content" => "report text"}}

      assert %{
               "content" => [%{"type" => "text", "text" => ~s({"content":"report text"})}],
               "structuredContent" => %{"content" => "report text"}
             } = MCPJobs.ExMCP.Store.call_tool_result(task)

      blocks = %{"content" => [%{"type" => "text", "text" => "hi"}]}

      assert ^blocks =
               MCPJobs.ExMCP.Store.call_tool_result(%Task{status: :completed, result: blocks})
    end
  end

  describe "release review" do
    test "a worker can choose the client message, and the details stay on the server" do
      for args <- [%{}, %{"atom_key" => true}] do
        {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(MCPJobs.Test.ClientMessageWorker, args)
        drain()

        assert {:ok,
                %{status: :failed, error: %{"message" => "Chosen message.", "details" => details}}} =
                 MCPJobs.status(task_id)

        assert details =~ "s3"
      end
    end

    test "a struct result is saved as a value and stays readable" do
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(MCPJobs.Test.StructResultWorker, %{})
      drain()

      assert {:ok, %{status: :completed, result: %{"value" => "2026-01-01T00:00:00Z"}}} =
               MCPJobs.status(task_id)
    end

    test "a literal backslash-u0000 text is a valid result" do
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(MCPJobs.Test.EscapedNulWorker, %{})
      drain()

      assert {:ok, %{status: :completed, result: %{"text" => "use \\u0000 to escape NUL"}}} =
               MCPJobs.status(task_id)
    end

    test "a repeated enqueue finds the task when the owner has atom values" do
      opts = [task_id: "owner-atoms", owner: %{role: :admin, id: 1}]
      {:ok, %Task{id: id}} = MCPJobs.enqueue(SuccessWorker, %{value: 1}, opts)

      assert {:ok, %Task{id: ^id}} = MCPJobs.enqueue(SuccessWorker, %{value: 1}, opts)
    end

    test "an exception as the error reason never reaches the client message" do
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(MCPJobs.Test.ExceptionReasonWorker, %{})
      drain()

      assert {:ok,
              %{status: :failed, error: %{"message" => "The task failed.", "details" => details}}} =
               MCPJobs.status(task_id)

      assert details =~ "sk-secret"
    end

    test "a struct with a NUL character fails the task" do
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(MCPJobs.Test.NulStructWorker, %{})
      drain()

      assert %Task{
               status: :failed,
               error: %{"message" => "The result could not be saved as JSON."}
             } =
               Repo.get_by(Task, task_id: task_id)
    end

    test "a result that cannot be saved as JSON keeps the reason in details" do
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(MCPJobs.Test.TupleWorker, %{})
      drain()

      assert %Task{error: %{"details" => "Protocol.UndefinedError"}} =
               Repo.get_by(Task, task_id: task_id)
    end

    test "a read between the discard and the telemetry event keeps the chosen message" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPJobs.enqueue(MCPJobs.Test.ClientMessageWorker, %{})

      Repo.update_all(where(Oban.Job, id: ^job_id),
        set: [state: "discarded", discarded_at: DateTime.utc_now()]
      )

      assert {:ok, %{status: :working}} = MCPJobs.status(task_id)

      MCPJobs.Telemetry.handle_event(
        [:oban, :job, :exception],
        %{},
        %{
          job: Repo.get(Oban.Job, job_id),
          state: :discard,
          conf: Oban.config(),
          result: {:error, %{"message" => "Chosen message."}}
        },
        nil
      )

      assert {:ok, %{status: :failed, error: %{"message" => "Chosen message."}}} =
               MCPJobs.status(task_id)
    end
  end

  describe "progress/4" do
    defp running_job(job_id), do: %{Repo.get(Oban.Job, job_id) | conf: Oban.config()}

    test "saves the progress while the task is working" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPJobs.enqueue(SuccessWorker, %{value: 1})

      assert :ok = MCPJobs.progress(running_job(job_id), 2, 5, "Rendering")

      assert {:ok,
              %{
                status: :working,
                progress: %{"current" => 2, "total" => 5, "message" => "Rendering"}
              }} =
               MCPJobs.status(task_id)

      assert :ok = MCPJobs.progress(running_job(job_id), 3)
      assert {:ok, %{progress: %{"current" => 3} = progress}} = MCPJobs.status(task_id)
      assert map_size(progress) == 1
    end

    test "sends a progress event" do
      attach_telemetry()

      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPJobs.enqueue(SuccessWorker, %{value: 1})

      :ok = MCPJobs.progress(running_job(job_id), 1, 2)

      assert_received {:telemetry, [:mcp_jobs, :task, :progress], %{system_time: _},
                       %{task_id: ^task_id, oban: Oban}}
    end

    test "does not change a finished task" do
      attach_telemetry()

      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPJobs.enqueue(SuccessWorker, %{value: 1})

      drain()

      assert :ok = MCPJobs.progress(running_job(job_id), 9, 9)
      assert %Task{status: :completed, progress: nil} = Repo.get_by(Task, task_id: task_id)
      refute_received {:telemetry, [:mcp_jobs, :task, :progress], _measurements, _metadata}
    end

    test "ignores a job without a task and rejects wrong values" do
      assert :ok = MCPJobs.progress(%Oban.Job{meta: %{}}, 1)

      assert_raise FunctionClauseError, fn ->
        MCPJobs.progress(%Oban.Job{meta: %{"mcp_task_id" => "x"}, conf: Oban.config()}, "1")
      end
    end

    test "await calls on_progress once for each change" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPJobs.enqueue(SuccessWorker, %{value: 1})

      test_pid = self()
      :ok = MCPJobs.progress(running_job(job_id), 1, 2)

      assert {:error, :timeout} =
               MCPJobs.await(task_id,
                 timeout: 100,
                 interval: 10,
                 on_progress: &send(test_pid, {:progress, &1})
               )

      assert_received {:progress, %{"current" => 1, "total" => 2}}
      refute_received {:progress, _}
    end

    test "await keeps the progress increasing after a retry" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} =
        MCPJobs.enqueue(SuccessWorker, %{value: 1})

      test_pid = self()

      waiter =
        Elixir.Task.async(fn ->
          MCPJobs.await(task_id,
            timeout: 1_000,
            interval: 5,
            on_progress: &send(test_pid, {:progress, &1})
          )
        end)

      for {current, message} <- [{1, "a"}, {2, "b"}, {3, "c"}, {1, "a"}, {1, "same"}, {2, "b"}] do
        :ok = MCPJobs.progress(running_job(job_id), current, 6, message)
        Process.sleep(50)
      end

      assert {:error, :timeout} = Elixir.Task.await(waiter)

      for {current, total, message} <- [
            {1, 6, "a"},
            {2, 6, "b"},
            {3, 6, "c"},
            {4, 9, "a"},
            {5, 9, "b"}
          ] do
        assert_received {:progress,
                         %{"current" => ^current, "total" => ^total, "message" => ^message}}
      end

      refute_received {:progress, _}
    end
  end

  describe "races" do
    test "a cancel after completion does nothing" do
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(SuccessWorker, %{value: 1})
      drain()

      assert {:error, :terminal} = MCPJobs.cancel(task_id)
      assert {:ok, %{status: :completed}} = MCPJobs.status(task_id)
    end

    test "a discard after cancel keeps the task cancelled" do
      {:ok, %Task{task_id: task_id, oban_job_id: job_id}} = MCPJobs.enqueue(FailingWorker, %{})
      Repo.update_all(where(Oban.Job, id: ^job_id), set: [state: "executing"])
      {:ok, _task} = MCPJobs.cancel(task_id)

      conf = Oban.config()
      assert :noop = MCPJobs.transition(conf, task_id, :failed, error: %{"message" => "late"})
      assert {:ok, %Task{status: :cancelled, error: nil}} = MCPJobs.get(task_id)
    end

    test "one change wins when complete, fail and cancel run at the same time" do
      {:ok, %Task{task_id: task_id}} = MCPJobs.enqueue(SuccessWorker, %{value: 1})
      conf = Oban.config()

      results =
        [
          fn -> MCPJobs.transition(conf, task_id, :completed, result: %{"value" => 1}) end,
          fn -> MCPJobs.transition(conf, task_id, :failed, error: %{"message" => "x"}) end,
          fn -> MCPJobs.cancel(task_id) end
        ]
        |> Enum.map(&Elixir.Task.async/1)
        |> Elixir.Task.await_many()

      winners = Enum.count(results, &match?({:ok, _task}, &1))

      assert winners == 1
      assert {:ok, %Task{status: status}} = MCPJobs.get(task_id)
      assert status in [:completed, :failed, :cancelled]
    end
  end

  describe "MCPJobs.Cleaner" do
    test "deletes old terminal tasks and keeps working tasks" do
      {:ok, %Task{task_id: done}} = MCPJobs.enqueue(SuccessWorker, %{value: 1})
      {:ok, %Task{task_id: running}} = MCPJobs.enqueue(FlakyWorker, %{succeed_on: 3})
      drain_once = Oban.drain_queue(queue: :default)
      assert %{success: 1, failure: 1} = drain_once

      old = DateTime.add(DateTime.utc_now(), -2, :day)
      Repo.update_all(Task, set: [updated_at: old])

      assert {:ok, 1} = perform_job(MCPJobs.Cleaner, %{})
      assert {:error, :not_found} = MCPJobs.status(done)
      assert {:ok, %{status: :working}} = MCPJobs.status(running)
    end
  end
end
