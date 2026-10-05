defmodule MCPJobs.ExMCPServerTest do
  use MCPJobs.DataCase

  alias ExMCP.Tasks.Extension

  setup do
    {:ok, server} =
      ExMCP.Server.HandlerServer.start_link(
        handler: MCPJobs.Test.MCPServer,
        transport: :beam,
        protocol_mode: :prefer_modern
      )

    {:ok, client} =
      ExMCP.Client.start_link(
        transport: :beam,
        server: server,
        protocol_mode: :prefer_modern,
        capabilities: Extension.put_capability(%{})
      )

    %{client: client}
  end

  test "a tool call returns a task, and tasks/get returns the job result", %{client: client} do
    {:ok, %{"resultType" => "task", "taskId" => task_id, "status" => "working"}} =
      ExMCP.Client.call_tool(client, "generate_report", %{"value" => 5}, format: :map)

    assert {:ok, %{"status" => "working"}} = ExMCP.Client.get_task(client, task_id)
    assert %Oban.Job{args: %{"value" => 5} = args} = Repo.one(Oban.Job)
    assert map_size(args) == 1

    drain()

    assert {:ok,
            %{"status" => "completed", "result" => %{"structuredContent" => %{"value" => 5}}}} =
             ExMCP.Client.get_task(client, task_id)
  end

  test "tasks/cancel cancels the job", %{client: client} do
    {:ok, %{"taskId" => task_id}} =
      ExMCP.Client.call_tool(client, "generate_report", %{"value" => 5}, format: :map)

    assert {:ok, _ack} = ExMCP.Client.cancel_task(client, task_id)
    assert {:ok, %{"status" => "cancelled"}} = ExMCP.Client.get_task(client, task_id)
    assert %Oban.Job{state: "cancelled"} = Repo.one(Oban.Job)
  end

  describe "notifications/tasks" do
    setup %{client: client} do
      {:ok, %{"taskId" => task_id}} =
        ExMCP.Client.call_tool(client, "generate_report", %{"value" => 5}, format: :map)

      {:ok, _ref} = ExMCP.Client.listen(client, %{"taskIds" => [task_id]})

      %{task_id: task_id}
    end

    test "a listening client gets the result of the job", %{task_id: task_id} do
      drain()

      assert_receive {:ex_mcp_subscription, _ref, "notifications/tasks",
                      %{
                        "taskId" => ^task_id,
                        "status" => "completed",
                        "result" => %{"structuredContent" => %{"value" => 5}}
                      }}
    end

    test "a listening client gets the progress of the job", %{task_id: task_id} do
      job = %{Repo.one(Oban.Job) | conf: Oban.config()}
      :ok = MCPJobs.progress(job, 2, 5, "Rendering")

      assert_receive {:ex_mcp_subscription, _ref, "notifications/tasks",
                      %{
                        "taskId" => ^task_id,
                        "status" => "working",
                        "statusMessage" => "Rendering (2/5)"
                      }}
    end

    test "a listening client gets a cancel from outside ExMCP", %{task_id: task_id} do
      {:ok, _task} = MCPJobs.cancel(task_id)

      assert_receive {:ex_mcp_subscription, _ref, "notifications/tasks",
                      %{"taskId" => ^task_id, "status" => "cancelled"}}
    end
  end
end
