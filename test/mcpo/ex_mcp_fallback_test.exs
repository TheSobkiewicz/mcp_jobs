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

  defp run_jobs_in_background do
    pid = spawn_link(&drain_loop/0)

    fn ->
      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end
  end

  defp drain_loop do
    receive do
      :stop -> :ok
    after
      20 ->
        drain()
        drain_loop()
    end
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
    end
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
end
