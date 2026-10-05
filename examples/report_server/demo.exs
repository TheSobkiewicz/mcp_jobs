alias ExMCP.Tasks.Extension

{:ok, server} =
  ExMCP.Server.HandlerServer.start_link(
    handler: ReportServer.MCPServer,
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

wait = fn wait, task_id ->
  {:ok, %{"status" => status} = task} = ExMCP.Client.get_task(client, task_id)
  IO.puts("  status: #{status} #{Map.get(task, "statusMessage", "")}")

  if status == "working" do
    Process.sleep(300)
    wait.(wait, task_id)
  else
    task
  end
end

IO.puts("1. Call the tool and wait for the result")

{:ok, %{"taskId" => task_id}} =
  ExMCP.Client.call_tool(client, "generate_report", %{"steps" => 3}, format: :map)

IO.puts("  task ID: #{task_id}")
%{"result" => %{"structuredContent" => result}} = wait.(wait, task_id)
IO.puts("  result: #{inspect(result)}")

IO.puts("2. Call the tool and cancel it while it runs")

{:ok, %{"taskId" => task_id}} =
  ExMCP.Client.call_tool(client, "generate_report", %{"steps" => 20}, format: :map)

Process.sleep(500)
{:ok, _ack} = ExMCP.Client.cancel_task(client, task_id)
wait.(wait, task_id)

Process.sleep(500)
{:ok, %MCPOban.Task{oban_job_id: job_id}} = MCPOban.get(task_id)
%Oban.Job{state: job_state} = ReportServer.Repo.get(Oban.Job, job_id)
IO.puts("  Oban job state after the worker stopped: #{job_state}")
