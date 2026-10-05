defmodule Mix.Tasks.Mcpo.InstallTest do
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
      Mix.Tasks.Mcpo.Install.run(["--server", "Shop.MCPServer", "--prefix", "private"])

      assert [migration] = Path.wildcard("priv/repo/migrations/*_add_mcpo_tasks.exs")
      assert migration =~ ~r/\d{14}_add_mcpo_tasks\.exs$/

      assert File.read!(migration) =~ "defmodule MCPO.Test.Repo.Migrations.AddMCPOTasks do"
      assert File.read!(migration) =~ ~s{MCPO.Migration.up(prefix: "private")}
      assert File.read!("lib/shop/mcp_server.ex") =~ "use MCPO.ExMCP,"

      assert [{MCPO.Test.Repo.Migrations.AddMCPOTasks, _}] = Code.compile_file(migration)
      assert [{Shop.MCPServer, _}] = Code.compile_file("lib/shop/mcp_server.ex")

      next_steps = Enum.find(shell_messages(), &(&1 =~ "Next steps"))
      assert next_steps =~ "mix ecto.migrate"
      assert next_steps =~ "MCPO.Cleaner"
      assert next_steps =~ "handler: Shop.MCPServer"

      Mix.Tasks.Mcpo.Install.run(["--no-server"])

      assert [^migration] = Path.wildcard("priv/repo/migrations/*_add_mcpo_tasks.exs")
      assert Enum.any?(shell_messages(), &(&1 =~ "skipping #{migration}"))
    end)
  end
end
