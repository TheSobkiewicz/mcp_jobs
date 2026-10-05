defmodule Mix.Tasks.Mcpo.Install do
  @shortdoc "Creates the MCPO migration and an MCP server module"

  @moduledoc """
  Creates the files that MCPO needs, and prints the remaining steps.

      $ mix mcpo.install

  It creates:

    * a migration for the `mcpo_tasks` table, in the migrations folder of the repo
    * an MCP server module, `lib/my_app/mcp_server.ex`, when `ex_mcp` is a dependency

  It does not change existing files. It asks before it replaces a file.

  ## Options

    * `--repo` (`-r`): the repo of the migration. The default is the first repo
      in `config :my_app, ecto_repos: [...]`.
    * `--server`: the name of the MCP server module. The default is
      `MyApp.MCPServer`.
    * `--no-server`: do not create the MCP server module.
    * `--prefix`: the database prefix of the Oban tables.
  """

  use Mix.Task

  import Mix.Generator

  @switches [repo: :string, server: :string, prefix: :string, no_server: :boolean]
  @aliases [r: :repo]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    Mix.Task.run("app.config")

    app = Mix.Project.config()[:app]
    base = app |> to_string() |> Macro.camelize()
    repo = repo(app, opts)

    create_migration(repo, opts)

    server = Keyword.get(opts, :server, "#{base}.MCPServer")
    create_server? = not Keyword.get(opts, :no_server, false) and Code.ensure_loaded?(ExMCP)

    if create_server?, do: create_server(server)

    Mix.shell().info(next_steps(app, server, create_server?))
  end

  defp repo(app, opts) do
    case {Keyword.get(opts, :repo), Application.get_env(app, :ecto_repos, [])} do
      {nil, [repo | _rest]} ->
        repo

      {nil, []} ->
        Mix.raise(
          "No repo found. Set config :#{app}, ecto_repos: [...] or pass --repo MyApp.Repo"
        )

      {repo, _repos} ->
        Module.concat([repo])
    end
  end

  defp create_migration(repo, opts) do
    Code.ensure_compiled!(repo)

    migrations = Path.join(repo_priv(repo), "migrations")

    case Path.wildcard(Path.join(migrations, "*_add_mcpo_tasks.exs")) do
      [] ->
        prefix_opts = if opts[:prefix], do: "prefix: #{inspect(opts[:prefix])}", else: ""
        file = Path.join(migrations, "#{timestamp()}_add_mcpo_tasks.exs")

        create_file(file, migration_template(repo: inspect(repo), opts: prefix_opts))

      [existing | _rest] ->
        Mix.shell().info([:yellow, "* skipping ", :reset, existing, " (already exists)"])
    end
  end

  defp repo_priv(repo) do
    default = Path.join("priv", repo |> Module.split() |> List.last() |> Macro.underscore())

    Keyword.get(repo.config(), :priv, default)
  end

  defp create_server(server) do
    file = Path.join("lib", Macro.underscore(server) <> ".ex")

    create_file(file, server_template(module: server))
  end

  defp next_steps(app, server, server_created?) do
    server_steps =
      if server_created? do
        """

        3. Add your workers to `tools:` in #{server}.

        4. Serve the MCP server. In a Phoenix router:

               forward "/mcp", ExMCP.HttpPlug, handler: #{server}, protocol_mode: :prefer_modern

           Or start it alone:

               Plug.Cowboy.http(ExMCP.HttpPlug, [handler: #{server}, protocol_mode: :prefer_modern], port: 4000)
        """
      else
        """

        3. Add {:ex_mcp, "~> 1.5"} to your deps and run `mix mcpo.install` again
           for an MCP server module. Or use MCPO.enqueue/3 with your own MCP server.
        """
      end

    """

    Next steps:

    1. Run the migration:

           mix ecto.migrate

       MCPO needs Oban. If Oban is not set up yet, see https://hexdocs.pm/oban.

    2. Delete old tasks every hour. Add MCPO.Cleaner to the Cron plugin of Oban:

           config :#{app}, Oban,
             plugins: [{Oban.Plugins.Cron, crontab: [{"@hourly", MCPO.Cleaner}]}]

       The Cleaner uses the :default queue. If your app does not run it, set a
       queue: {"@hourly", MCPO.Cleaner, queue: :maintenance}

       If your Oban instance is not named Oban, also add:

           config :mcpo, oban: MyApp.Oban
    """ <> server_steps
  end

  defp timestamp do
    {{year, month, day}, {hour, minute, second}} = :calendar.universal_time()

    [year, month, day, hour, minute, second]
    |> Enum.map_join(&String.pad_leading(Integer.to_string(&1), 2, "0"))
  end

  embed_template(:migration, """
  defmodule <%= @repo %>.Migrations.AddMCPOTasks do
    use Ecto.Migration

    def up, do: MCPO.Migration.up(<%= @opts %>)
    def down, do: MCPO.Migration.down(<%= @opts %>)
  end
  """)

  embed_template(:server, """
  defmodule <%= @module %> do
    @moduledoc \"\"\"
    The MCP server. Each tool runs as an Oban job.
    \"\"\"

    use MCPO.ExMCP,
      tools: [
        # MyApp.Workers.GenerateReport
      ]
  end
  """)
end
