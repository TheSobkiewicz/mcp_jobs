defmodule MCPO.ExMCPToolsTest do
  use MCPO.DataCase

  alias MCPO.Test.{PlainWorker, SuccessWorker}

  defp start_client(protocol_mode) do
    {:ok, server} =
      ExMCP.Server.HandlerServer.start_link(
        handler: MCPO.Test.MCPServer,
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
                 "description" => "Runs MCPO.Test.HiddenDocWorker as a background job."
               },
               %{"name" => "plain_worker", "inputSchema" => %{"type" => "object"}},
               %{
                 "name" => "summary_override",
                 "description" => "Override.",
                 "inputSchema" => %{"properties" => %{"text" => _}}
               }
             ] = Enum.sort_by(tools, &Map.fetch!(&1, "name"))
    end
  end

  test "MCPO.Tool keeps the moduledoc and the options of the worker" do
    assert [description: "Builds a summary.", input_schema: %{"type" => "object"} = _schema] =
             Enum.sort(MCPO.Tool.options(MCPO.Test.DocumentedWorker))

    assert [name: "hidden"] = MCPO.Tool.options(MCPO.Test.HiddenDocWorker)
    assert [] = MCPO.Tool.options(PlainWorker)
  end

  test "an unknown tool returns an error" do
    client = start_client(:prefer_modern)

    assert {:error, _error} = ExMCP.Client.call_tool(client, "missing", %{}, format: :map)
  end

  test "initialize returns the tools capability" do
    assert %{"capabilities" => %{"tools" => %{}}, "protocolVersion" => "2025-06-18"} =
             MCPO.ExMCP.__initialize__(%{"protocolVersion" => "2025-06-18"}, %{})

    assert %{"protocolVersion" => "2025-11-25"} =
             MCPO.ExMCP.__initialize__(%{"protocolVersion" => "1999-01-01"}, %{})
  end

  test "rejects duplicate tool names and modules that are not workers" do
    assert_raise ArgumentError, ~r/duplicate MCPO tool names/, fn ->
      MCPO.ExMCP.__tools__([SuccessWorker, {PlainWorker, name: "success_worker"}])
    end

    assert_raise ArgumentError, ~r/is not an Oban worker/, fn ->
      MCPO.ExMCP.__tools__([MCPO.Task])
    end
  end
end
