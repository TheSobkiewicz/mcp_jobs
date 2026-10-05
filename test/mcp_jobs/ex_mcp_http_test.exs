defmodule MCPJobs.ExMCPHttpTest do
  use MCPJobs.DataCase

  @moduletag :unsandboxed

  setup do
    ref = make_ref()

    {:ok, _pid} =
      Plug.Cowboy.http(
        ExMCP.HttpPlug,
        [
          handler: MCPJobs.Test.MCPServer,
          protocol_mode: :prefer_modern,
          allowed_origins: :any,
          server_info: MCPJobs.Test.MCPServer.server_info()
        ],
        port: 0,
        ref: ref
      )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)

    {:ok, client} =
      ExMCP.Client.start_link(
        transport: :http,
        url: "http://localhost:#{:ranch.get_port(ref)}/",
        protocol_mode: :prefer_modern
      )

    %{client: client}
  end

  test "a modern HTTP client sees the tools and the server name", %{client: client} do
    assert {:ok, %{"tools" => %{}}} = ExMCP.Client.server_capabilities(client)
    assert {:ok, %{"name" => "MCPJobs.Test.MCPServer"}} = ExMCP.Client.server_info(client)
    assert {:ok, %{"tools" => [_tool | _rest]}} = ExMCP.Client.list_tools(client, format: :map)
  end
end
