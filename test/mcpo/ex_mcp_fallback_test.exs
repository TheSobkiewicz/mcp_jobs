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
    test_pid = self()

    pid =
      spawn_link(fn ->
        Stream.repeatedly(fn ->
          drain()
          Process.sleep(20)
        end)
        |> Stream.take_while(fn _ -> Process.alive?(test_pid) end)
        |> Stream.run()
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
  end

  for {mode, label} <- [prefer_modern: "a modern client", legacy_only: "a legacy client"] do
    test "#{label} without tasks gets the result directly" do
      client = start_client(unquote(mode), %{})
      run_jobs_in_background()

      assert {:ok, %{"structuredContent" => %{"value" => 4}} = result} =
               ExMCP.Client.call_tool(client, "generate_report", %{"value" => 4}, format: :map)

      refute Map.has_key?(result, "taskId")
      assert %Task{status: :completed} = Repo.one(Task)
    end
  end

  test "a failed job returns an error result" do
    client = start_client(:prefer_modern, %{})
    run_jobs_in_background()

    assert {:ok, %{"isError" => true, "content" => [%{"text" => text}]}} =
             ExMCP.Client.call_tool(client, "failing_report", %{}, format: :map)

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
