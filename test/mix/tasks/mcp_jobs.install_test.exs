defmodule Mix.Tasks.McpJobs.InstallTest do
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
      Mix.Tasks.McpJobs.Install.run(["--server", "Shop.MCPServer", "--prefix", "private"])

      assert [migration] = Path.wildcard("priv/repo/migrations/*_add_mcp_jobs_tasks.exs")
      assert migration =~ ~r/\d{14}_add_mcp_jobs_tasks\.exs$/

      assert File.read!(migration) =~ "defmodule MCPJobs.Test.Repo.Migrations.AddMCPJobsTasks do"
      assert File.read!(migration) =~ ~s{MCPJobs.Migration.up(prefix: "private")}
      assert File.read!("lib/shop/mcp_server.ex") =~ "use MCPJobs.ExMCP,"
      assert File.read!("lib/shop/mcp_server.ex") =~ "task_store_opts: [wait_timeout: 300_000]"

      assert [{MCPJobs.Test.Repo.Migrations.AddMCPJobsTasks, _}] = Code.compile_file(migration)
      assert [{Shop.MCPServer, _}] = Code.compile_file("lib/shop/mcp_server.ex")

      next_steps = Enum.find(shell_messages(), &(&1 =~ "Next steps"))
      assert next_steps =~ "mix ecto.migrate"
      assert next_steps =~ "MCPJobs.Cleaner"
      assert next_steps =~ "handler: Shop.MCPServer"
      assert next_steps =~ "handler_call_timeout: 305_000"
      assert next_steps =~ "idle_timeout: 310_000"

      Mix.Tasks.McpJobs.Install.run(["--no-server"])

      assert [^migration] = Path.wildcard("priv/repo/migrations/*_add_mcp_jobs_tasks.exs")
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

      Mix.Tasks.McpJobs.Install.run(args)

      router = File.read!("lib/shop_web/router.ex")

      assert router =~ """
               scope "/mcp" do
                 forward "/", ExMCP.HttpPlug,
                   handler: Shop.MCPServer,
                   protocol_mode: :prefer_modern,
                   handler_call_timeout: 305_000
               end
             end
             """

      assert {:ok, _ast} = Code.string_to_quoted(router)
      assert Enum.any?(shell_messages(), &(&1 =~ "The MCP server is at /mcp"))

      Mix.Tasks.McpJobs.Install.run(args)

      assert File.read!("lib/shop_web/router.ex") == router
      assert Enum.any?(shell_messages(), &(&1 =~ "it already routes to ExMCP"))
    end)
  end

  @tag :tmp_dir
  test "--phoenix without a router stops with a clear error", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      assert_raise Mix.Error, ~r/No Phoenix router at lib\/mcp_jobs_web\/router.ex/, fn ->
        Mix.Tasks.McpJobs.Install.run(["--phoenix", "--no-server"])
      end
    end)
  end
end
