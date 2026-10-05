defmodule Mix.Tasks.McpJobs.Install do
  @shortdoc "Creates the MCPJobs migration and an MCP server module"

  @moduledoc """
  Creates the files that MCPJobs needs, and prints the remaining steps.

      $ mix mcp_jobs.install

  It creates:

    * a migration for the MCPJobs tables, in the migrations folder of the repo
    * an MCP server module, `lib/my_app/mcp_server.ex`, when `ex_mcp` is a dependency
    * with `--phoenix`, the `/mcp` route in the Phoenix router

  It changes no existing file, except the router with `--phoenix`. It asks
  before it replaces a file.

  ## Options

    * `--repo` (`-r`): the repo of the migration. The default is the first repo
      in `config :my_app, ecto_repos: [...]`.
    * `--server`: the name of the MCP server module. The default is
      `MyApp.MCPServer`.
    * `--no-server`: do not create the MCP server module.
    * `--prefix`: the database prefix of the Oban tables.
    * `--phoenix`: add the MCP server to the Phoenix router at `/mcp`.
    * `--router`: the path of the Phoenix router. The default is
      `lib/my_app_web/router.ex`.
  """

  use Mix.Task

  import Mix.Generator

  @switches [
    repo: :string,
    server: :string,
    prefix: :string,
    no_server: :boolean,
    phoenix: :boolean,
    router: :string
  ]
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

    route_added? = Keyword.get(opts, :phoenix, false) and add_route(app, server, opts)

    Mix.shell().info(next_steps(app, server, create_server?, route_added?))
  end

  defp add_route(app, server, opts) do
    router = Keyword.get(opts, :router, Path.join(["lib", "#{app}_web", "router.ex"]))

    cond do
      not Code.ensure_loaded?(ExMCP) ->
        Mix.shell().error(
          "--phoenix needs {:ex_mcp, \"~> 1.5\"} in your deps. No route was added."
        )

        false

      not File.exists?(router) ->
        Mix.raise("No Phoenix router at #{router}. Pass --router path/to/router.ex")

      File.read!(router) =~ "ExMCP.HttpPlug" ->
        Mix.shell().info([
          :yellow,
          "* skipping ",
          :reset,
          router,
          " (it already routes to ExMCP)"
        ])

        true

      true ->
        insert_route(router, server)
        true
    end
  end

  # Adds the scope before the last `end`, which closes the router module.
  defp insert_route(router, server) do
    source = router |> File.read!() |> String.trim_trailing()

    if not String.ends_with?(source, "end") do
      Mix.raise("Cannot find the end of the router module in #{router}")
    end

    route = """

      scope "/mcp" do
        forward "/", ExMCP.HttpPlug, handler: #{server}, protocol_mode: :prefer_modern
      end
    end
    """

    body = source |> String.replace_suffix("end", "") |> String.trim_trailing()
    File.write!(router, body <> "\n" <> route)

    Mix.shell().info([:green, "* updating ", :reset, router])
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

    case Path.wildcard(Path.join(migrations, "*_add_mcp_jobs_tasks.exs")) do
      [] ->
        prefix_opts = if opts[:prefix], do: "prefix: #{inspect(opts[:prefix])}", else: ""
        file = Path.join(migrations, "#{timestamp()}_add_mcp_jobs_tasks.exs")

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

  defp next_steps(app, server, server_created?, route_added?) do
    server_steps =
      cond do
        route_added? ->
          """

          3. Add your workers to `tools:` in #{server}.

          4. The MCP server is at /mcp in your Phoenix app. Put your auth plugs in
             front of it (a pipeline in the "/mcp" scope), so that only allowed
             clients can call the tools.
          """

        server_created? ->
          """

          3. Add your workers to `tools:` in #{server}.

          4. Serve the MCP server. In a Phoenix router (or run with --phoenix):

                 forward "/mcp", ExMCP.HttpPlug, handler: #{server}, protocol_mode: :prefer_modern

             Or start it alone:

                 Plug.Cowboy.http(ExMCP.HttpPlug, [handler: #{server}, protocol_mode: :prefer_modern], port: 4000)
          """

        true ->
          """

          3. Add {:ex_mcp, "~> 1.5"} to your deps and run `mix mcp_jobs.install` again
             for an MCP server module. Or use MCPJobs.enqueue/3 with your own MCP server.
          """
      end

    """

    Next steps:

    1. Run the migration:

           mix ecto.migrate

       MCPJobs needs Oban. If Oban is not set up yet, see https://hexdocs.pm/oban.

    2. Delete old tasks every hour. Add MCPJobs.Cleaner to the Cron plugin of Oban:

           config :#{app}, Oban,
             plugins: [{Oban.Plugins.Cron, crontab: [{"@hourly", MCPJobs.Cleaner}]}]

       The Cleaner uses the :default queue. If your app does not run it, set a
       queue: {"@hourly", MCPJobs.Cleaner, queue: :maintenance}

       If your Oban instance is not named Oban, also add:

           config :mcp_jobs, oban: MyApp.Oban
    """ <> server_steps
  end

  defp timestamp do
    {{year, month, day}, {hour, minute, second}} = :calendar.universal_time()

    [year, month, day, hour, minute, second]
    |> Enum.map_join(&String.pad_leading(Integer.to_string(&1), 2, "0"))
  end

  embed_template(:migration, """
  defmodule <%= @repo %>.Migrations.AddMCPJobsTasks do
    use Ecto.Migration

    def up, do: MCPJobs.Migration.up(<%= @opts %>)
    def down, do: MCPJobs.Migration.down(<%= @opts %>)
  end
  """)

  embed_template(:server, """
  defmodule <%= @module %> do
    @moduledoc \"\"\"
    The MCP server. Each tool runs as an Oban job.
    \"\"\"

    use MCPJobs.ExMCP,
      tools: [
        # MyApp.Workers.GenerateReport
      ]
  end
  """)
end
