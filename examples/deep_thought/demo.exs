alias ExMCP.Tasks.Extension

{:ok, server} =
  ExMCP.Server.HandlerServer.start_link(
    handler: DeepThought.MCPServer,
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

ask = fn arguments ->
  {:ok, %{"taskId" => task_id}} =
    ExMCP.Client.call_tool(client, "answer_ultimate_question", arguments, format: :map)

  {:ok, _subscription} = ExMCP.Client.listen(client, %{"taskIds" => [task_id]})
  IO.puts("  task #{task_id} started. Deep Thought sends updates:")
  task_id
end

# Prints the task notifications until the task is done, or until the
# status message ends with `stop_at`.
follow = fn follow, stop_at ->
  receive do
    {:ex_mcp_subscription, _ref, "notifications/tasks", %{"status" => "working"} = task} ->
      message = Map.get(task, "statusMessage", "")
      IO.puts("  working: #{message}")
      if stop_at && String.ends_with?(message, stop_at), do: task, else: follow.(follow, stop_at)

    {:ex_mcp_subscription, _ref, "notifications/tasks", %{"status" => status} = task} ->
      IO.puts("  #{status}")
      task
  after
    15_000 ->
      IO.puts("""

      No notification in 15 seconds. Is serve.exs or serve_fastest.exs running?
      They use the same database and queue, so their Oban can run the job, and
      ExMCP sends notifications only on the node that ran it. Stop them, then
      run the demo again.
      """)

      System.halt(1)
  end
end

IO.puts("""

1. Ask Deep Thought the Ultimate Question.
   On the first attempt a mouse interrupts it. Oban retries the job,
   and the task stays "working".
""")

task_id = ask.(%{})
%{"result" => %{"structuredContent" => answer}} = follow.(follow, nil)
IO.puts("  answer: #{answer["answer"]}")
IO.puts("  comment: #{answer["comment"]}")

{:ok, %MCPJobs.Task{oban_job_id: job_id}} = MCPJobs.get(task_id)
%Oban.Job{attempt: attempts} = DeepThought.Repo.get(Oban.Job, job_id)
IO.puts("  Oban attempts: #{attempts}")

IO.puts("""

2. Ask again. The Vogons demolish the Earth during the calculation.
""")

task_id = ask.(%{"question" => "And what about the dolphins?"})
follow.(follow, "(2/6)")
IO.puts("  The Vogons arrive: the client cancels the task.")
{:ok, _ack} = ExMCP.Client.cancel_task(client, task_id)
follow.(follow, nil)

Process.sleep(1_000)
{:ok, %MCPJobs.Task{oban_job_id: job_id}} = MCPJobs.get(task_id)
%Oban.Job{state: job_state} = DeepThought.Repo.get(Oban.Job, job_id)
IO.puts("  Oban job state: #{job_state}")

IO.puts("""

3. Ask for the Ultimate Question itself. Deep Thought cannot do it.
   Oban tries 3 times, then the task fails.
""")

task_id = ask.(%{"question" => "What is the Ultimate Question?"})
follow.(follow, nil)

{:ok, %{"error" => %{"message" => message}}} = ExMCP.Client.get_task(client, task_id)
IO.puts("  the client sees: #{message}")

{:ok, %{error: %{"details" => details}}} = MCPJobs.status(task_id)
IO.puts("  only the server sees the details: #{details}")
