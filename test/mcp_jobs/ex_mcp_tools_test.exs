defmodule MCPJobs.ExMCPToolsTest do
  use MCPJobs.DataCase

  alias MCPJobs.Test.{PlainWorker, SuccessWorker}

  defp start_client(protocol_mode) do
    {:ok, server} =
      ExMCP.Server.HandlerServer.start_link(
        handler: MCPJobs.Test.MCPServer,
        transport: :beam,
        protocol_mode: protocol_mode
      )

    {:ok, client} =
      ExMCP.Client.start_link(transport: :beam, server: server, protocol_mode: protocol_mode)

    client
  end

  for mode <- [:prefer_modern, :legacy_only] do
    test "lists the workers as tools (#{mode})" do
      client = start_client(unquote(mode))

      assert {:ok, %{"tools" => tools}} = ExMCP.Client.list_tools(client, format: :map)

      assert [
               %{
                 "name" => "documented_worker",
                 "description" => "Builds a summary.",
                 "inputSchema" => %{"properties" => %{"text" => _}}
               },
               %{"name" => "failing_report"},
               %{
                 "name" => "generate_report",
                 "description" => "Generates a report in the background.",
                 "inputSchema" => %{"properties" => %{"value" => _}}
               },
               %{
                 "name" => "hidden",
                 "description" => "Runs MCPJobs.Test.HiddenDocWorker as a background job."
               },
               %{"name" => "plain_worker", "inputSchema" => %{"type" => "object"}},
               %{
                 "name" => "summary_override",
                 "description" => "Override.",
                 "inputSchema" => %{"properties" => %{"text" => _}}
               },
               %{"name" => "unique_report"}
             ] = Enum.sort_by(tools, &Map.fetch!(&1, "name"))
    end
  end

  test "MCPJobs.Tool keeps the moduledoc and the options of the worker" do
    assert [description: "Builds a summary.", input_schema: %{"type" => "object"} = _schema] =
             Enum.sort(MCPJobs.Tool.options(MCPJobs.Test.DocumentedWorker))

    assert [name: "hidden"] = MCPJobs.Tool.options(MCPJobs.Test.HiddenDocWorker)
    assert [] = MCPJobs.Tool.options(PlainWorker)
  end

  test "invalid arguments return an error result and start no job" do
    client = start_client(:prefer_modern)

    assert {:ok, %{"isError" => true, "content" => [%{"text" => text}]}} =
             ExMCP.Client.call_tool(client, "generate_report", %{"value" => "five"}, format: :map)

    assert text =~ "Invalid arguments: "
    assert text =~ "value"
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert Repo.aggregate(MCPJobs.Task, :count) == 0
  end

  test "rejects an invalid input schema" do
    assert_raise ArgumentError, ~r/invalid input schema for MCPJobs.Test.PlainWorker/, fn ->
      MCPJobs.ExMCP.__tools__([{PlainWorker, input_schema: %{"type" => 5}}])
    end
  end

  test "an unknown tool returns an error" do
    client = start_client(:prefer_modern)

    assert {:error, _error} = ExMCP.Client.call_tool(client, "missing", %{}, format: :map)
  end

  test "initialize returns the tools capability" do
    assert %{"capabilities" => %{"tools" => %{}}, "protocolVersion" => "2025-06-18"} =
             MCPJobs.ExMCP.__initialize__(%{"protocolVersion" => "2025-06-18"}, %{})

    assert %{"protocolVersion" => "2025-11-25"} =
             MCPJobs.ExMCP.__initialize__(%{"protocolVersion" => "1999-01-01"}, %{})
  end

  test "server_info/0 returns the server name" do
    assert %{"name" => "MCPJobs.Test.MCPServer", "version" => "1.0.0"} =
             MCPJobs.Test.MCPServer.server_info()
  end

  test "rejects duplicate tool names and modules that are not workers" do
    assert_raise ArgumentError, ~r/duplicate MCPJobs tool names/, fn ->
      MCPJobs.ExMCP.__tools__([SuccessWorker, {PlainWorker, name: "success_worker"}])
    end

    assert_raise ArgumentError, ~r/is not an Oban worker/, fn ->
      MCPJobs.ExMCP.__tools__([MCPJobs.Task])
    end
  end
end
