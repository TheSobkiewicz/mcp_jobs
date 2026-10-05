defmodule MCPO.ExMCPServerTest do
  use MCPO.DataCase

  alias ExMCP.Tasks.Extension

  setup do
    {:ok, server} =
      ExMCP.Server.HandlerServer.start_link(
        handler: MCPO.Test.MCPServer,
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
end
