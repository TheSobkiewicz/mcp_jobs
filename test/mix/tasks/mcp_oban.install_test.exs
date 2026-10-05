defmodule Mix.Tasks.McpOban.InstallTest do
  use ExUnit.Case

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  defp shell_messages do
    receive do
      {:mix_shell, :info, [message]} -> [IO.iodata_to_binary(message) | shell_messages()]
    after
      0 -> []
    end
  end

  @tag :tmp_dir
  test "creates the migration and the server module, and prints the next steps", %{
    tmp_dir: tmp_dir
  } do
    File.cd!(tmp_dir, fn ->
      Mix.Tasks.McpOban.Install.run(["--server", "Shop.MCPServer", "--prefix", "private"])

      assert [migration] = Path.wildcard("priv/repo/migrations/*_add_mcp_oban_tasks.exs")
      assert migration =~ ~r/\d{14}_add_mcp_oban_tasks\.exs$/

      assert File.read!(migration) =~ "defmodule MCPOban.Test.Repo.Migrations.AddMCPObanTasks do"
      assert File.read!(migration) =~ ~s{MCPOban.Migration.up(prefix: "private")}
      assert File.read!("lib/shop/mcp_server.ex") =~ "use MCPOban.ExMCP,"

      assert [{MCPOban.Test.Repo.Migrations.AddMCPObanTasks, _}] = Code.compile_file(migration)
      assert [{Shop.MCPServer, _}] = Code.compile_file("lib/shop/mcp_server.ex")

      next_steps = Enum.find(shell_messages(), &(&1 =~ "Next steps"))
      assert next_steps =~ "mix ecto.migrate"
      assert next_steps =~ "MCPOban.Cleaner"
      assert next_steps =~ "handler: Shop.MCPServer"

      Mix.Tasks.McpOban.Install.run(["--no-server"])

      assert [^migration] = Path.wildcard("priv/repo/migrations/*_add_mcp_oban_tasks.exs")
      assert Enum.any?(shell_messages(), &(&1 =~ "skipping #{migration}"))
    end)
  end

  @router """
  defmodule ShopWeb.Router do
    use ShopWeb, :router

    scope "/", ShopWeb do
      get "/", PageController, :home
    end
  end
  """

  @tag :tmp_dir
  test "--phoenix adds the /mcp route to the router once", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      File.mkdir_p!("lib/shop_web")
      File.write!("lib/shop_web/router.ex", @router)
      args = ["--server", "Shop.MCPServer", "--phoenix", "--router", "lib/shop_web/router.ex"]

      Mix.Tasks.McpOban.Install.run(args)

      router = File.read!("lib/shop_web/router.ex")

      assert router =~ """
               scope "/mcp" do
                 forward "/", ExMCP.HttpPlug, handler: Shop.MCPServer, protocol_mode: :prefer_modern
               end
             end
             """

      assert {:ok, _ast} = Code.string_to_quoted(router)
      assert Enum.any?(shell_messages(), &(&1 =~ "The MCP server is at /mcp"))

      Mix.Tasks.McpOban.Install.run(args)

      assert File.read!("lib/shop_web/router.ex") == router
      assert Enum.any?(shell_messages(), &(&1 =~ "it already routes to ExMCP"))
    end)
  end

  @tag :tmp_dir
  test "--phoenix without a router stops with a clear error", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      assert_raise Mix.Error, ~r/No Phoenix router at lib\/mcp_oban_web\/router.ex/, fn ->
        Mix.Tasks.McpOban.Install.run(["--phoenix", "--no-server"])
      end
    end)
  end
end
