defmodule MCPOban.ExMCPToolsTest do
  use MCPOban.DataCase

  alias MCPOban.Test.{PlainWorker, SuccessWorker}

  defp start_client(protocol_mode) do
    {:ok, server} =
      ExMCP.Server.HandlerServer.start_link(
        handler: MCPOban.Test.MCPServer,
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
                 "description" => "Runs MCPOban.Test.HiddenDocWorker as a background job."
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

  test "MCPOban.Tool keeps the moduledoc and the options of the worker" do
    assert [description: "Builds a summary.", input_schema: %{"type" => "object"} = _schema] =
             Enum.sort(MCPOban.Tool.options(MCPOban.Test.DocumentedWorker))

    assert [name: "hidden"] = MCPOban.Tool.options(MCPOban.Test.HiddenDocWorker)
    assert [] = MCPOban.Tool.options(PlainWorker)
  end

  test "invalid arguments return an error result and start no job" do
    client = start_client(:prefer_modern)

    assert {:ok, %{"isError" => true, "content" => [%{"text" => text}]}} =
             ExMCP.Client.call_tool(client, "generate_report", %{"value" => "five"}, format: :map)

    assert text =~ "Invalid arguments: "
    assert text =~ "value"
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert Repo.aggregate(MCPOban.Task, :count) == 0
  end

  test "rejects an invalid input schema" do
    assert_raise ArgumentError, ~r/invalid input schema for MCPOban.Test.PlainWorker/, fn ->
      MCPOban.ExMCP.__tools__([{PlainWorker, input_schema: %{"type" => 5}}])
    end
  end

  test "an unknown tool returns an error" do
    client = start_client(:prefer_modern)

    assert {:error, _error} = ExMCP.Client.call_tool(client, "missing", %{}, format: :map)
  end

  test "initialize returns the tools capability" do
    assert %{"capabilities" => %{"tools" => %{}}, "protocolVersion" => "2025-06-18"} =
             MCPOban.ExMCP.__initialize__(%{"protocolVersion" => "2025-06-18"}, %{})

    assert %{"protocolVersion" => "2025-11-25"} =
             MCPOban.ExMCP.__initialize__(%{"protocolVersion" => "1999-01-01"}, %{})
  end

  test "rejects duplicate tool names and modules that are not workers" do
    assert_raise ArgumentError, ~r/duplicate MCPOban tool names/, fn ->
      MCPOban.ExMCP.__tools__([SuccessWorker, {PlainWorker, name: "success_worker"}])
    end

    assert_raise ArgumentError, ~r/is not an Oban worker/, fn ->
      MCPOban.ExMCP.__tools__([MCPOban.Task])
    end
  end
end
