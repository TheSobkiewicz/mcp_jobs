# Installation

```elixir
def deps do
  [
    {:mcp_jobs, "~> 0.1"},
    # Optional, for the ExMCP adapter:
    {:ex_mcp, "~> 1.5"}
  ]
end
```

MCPJobs needs [Oban](https://hexdocs.pm/oban) with PostgreSQL. It does not work with the MySQL or SQLite engines of Oban. Set up Oban first, then run:

```sh
mix mcp_jobs.install
```

It creates a migration for the MCPJobs tables and, with `ex_mcp`, an MCP server module. Then it prints the next steps. Options: `--repo MyApp.Repo`, `--server MyApp.MCPServer`, `--no-server`, and `--prefix private`.

In a Phoenix app, add `--phoenix`. The installer then also adds the MCP server to the router:

```elixir
scope "/mcp" do
  forward "/", ExMCP.HttpPlug, handler: MyApp.MCPServer, protocol_mode: :prefer_modern
end
```

It looks for `lib/my_app_web/router.ex`; `--router path/to/router.ex` sets another file. Put your auth plugs in front of the route, so that only allowed clients can call the tools.

## Manual setup

MCPJobs uses the repo of your Oban instance. Add a migration:

```elixir
defmodule MyApp.Repo.Migrations.AddMCPJobsTasks do
  use Ecto.Migration

  def up, do: MCPJobs.Migration.up()
  def down, do: MCPJobs.Migration.down()
end
```

If Oban uses a prefix, pass the same prefix: `MCPJobs.Migration.up(prefix: "private")`.

If your Oban instance does not have the name `Oban`, set the name:

```elixir
config :mcp_jobs, oban: MyApp.Oban
```
