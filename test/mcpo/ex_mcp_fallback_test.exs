defmodule MCPO.ExMCPFallbackTest do
  use MCPO.DataCase

  alias MCPO.Task

  defp start_client(protocol_mode, capabilities) do
    {:ok, server} =
      ExMCP.Server.HandlerServer.start_link(
        handler: MCPO.Test.MCPServer,
        transport: :beam,
        protocol_mode: protocol_mode
      )

    {:ok, client} =
      ExMCP.Client.start_link(
        transport: :beam,
        server: server,
        protocol_mode: protocol_mode,
        capabilities: capabilities
      )

    client
  end

  for {mode, label} <- [prefer_modern: "a modern client", legacy_only: "a legacy client"] do
    test "#{label} without tasks gets the result directly" do
      client = start_client(unquote(mode), %{})
      stop_jobs = run_jobs_in_background()

      assert {:ok, %{"structuredContent" => %{"value" => 4}} = result} =
               ExMCP.Client.call_tool(client, "generate_report", %{"value" => 4}, format: :map)

      stop_jobs.()
      refute Map.has_key?(result, "taskId")
      assert %Task{status: :completed} = Repo.one(Task)
      assert %Oban.Job{args: %{"value" => 4} = args} = Repo.one(Oban.Job)
      assert map_size(args) == 1
    end
  end

  test "a duplicate call through ExMCP finds the unique job" do
    {:ok, _task} = MCPO.enqueue(MCPO.Test.UniqueWorker, %{"q" => 1})
    client = start_client(:prefer_modern, %{})

    assert {:ok, %{"isError" => true, "content" => [%{"text" => text}]}} =
             ExMCP.Client.call_tool(client, "unique_report", %{"q" => 1}, format: :map)

    assert text == "A job with the same arguments already exists."
  end

  test "a failed job returns an error result" do
    client = start_client(:prefer_modern, %{})
    stop_jobs = run_jobs_in_background()

    assert {:ok, %{"isError" => true, "content" => [%{"text" => text}]}} =
             ExMCP.Client.call_tool(client, "failing_report", %{}, format: :map)

    stop_jobs.()
    assert text =~ "boom"
  end

  test "a job that does not finish in time is cancelled" do
    client = start_client(:prefer_modern, %{})

    assert {:ok, %{"isError" => true, "content" => [%{"text" => text}]}} =
             ExMCP.Client.call_tool(client, "slow_report", %{"value" => 1}, format: :map)

    assert text =~ "did not finish in 200 ms"
    assert %Task{status: :cancelled} = Repo.one(Task)
    assert %Oban.Job{state: "cancelled"} = Repo.one(Oban.Job)
  end

  for {tool, job_state} <- [{"slow_report", "executing"}, {"slow_kill_report", "cancelled"}] do
    test "on timeout, #{tool} leaves a running job #{job_state}" do
      client = start_client(:prefer_modern, %{})
      mark_running = mark_job_running_in_background()

      assert {:ok, %{"isError" => true}} =
               ExMCP.Client.call_tool(client, unquote(tool), %{"value" => 1}, format: :map)

      mark_running.()
      assert %Task{status: :cancelled} = Repo.one(Task)
      assert %Oban.Job{state: unquote(job_state)} = Repo.one(Oban.Job)
    end
  end

  test "a duplicate unique job returns an error result" do
    {:ok, _task} = MCPO.enqueue(MCPO.Test.UniqueWorker, %{"q" => 1})
    specs = MCPO.ExMCP.__tools__([{MCPO.Test.UniqueWorker, name: "unique_report"}])

    assert {:ok, %{"isError" => true, "content" => [%{"text" => text}]}, :state} =
             MCPO.ExMCP.__call_tool__(specs, "unique_report", %{"q" => 1}, :state, [])

    assert text == "A job with the same arguments already exists."
  end

  test "a task that finished just before the timeout cancel returns its real result" do
    {:ok, %Task{task_id: done}} = MCPO.enqueue(MCPO.Test.SuccessWorker, %{value: 3})
    {:ok, %Task{task_id: failed}} = MCPO.enqueue(MCPO.Test.FailingWorker, %{})
    drain()

    assert %{"structuredContent" => %{"value" => 3}} = MCPO.ExMCP.__timed_out__(done, 100, [])

    assert %{"isError" => true, "content" => [%{"text" => text}]} =
             MCPO.ExMCP.__timed_out__(failed, 100, [])

    assert text =~ "boom"
  end

  # Sets the first job that appears to "executing", as if a queue had started it.
  defp mark_job_running_in_background do
    task = Elixir.Task.async(&mark_first_job_running/0)
    fn -> Elixir.Task.await(task) end
  end

  defp mark_first_job_running do
    case Repo.update_all(Oban.Job, set: [state: "executing"]) do
      {0, _} ->
        Process.sleep(10)
        mark_first_job_running()

      {_count, _} ->
        :ok
    end
  end
end
