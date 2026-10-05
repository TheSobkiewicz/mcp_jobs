defmodule MCPJobs.Migration do
  @moduledoc """
  Creates the MCPJobs tables.

  Call it from a migration in your application:

      defmodule MyApp.Repo.Migrations.AddMCPJobsTasks do
        use Ecto.Migration

        def up, do: MCPJobs.Migration.up()
        def down, do: MCPJobs.Migration.down()
      end

  It creates two tables:

    * `mcp_jobs_tasks`: the MCP tasks.
    * `mcp_jobs_fastest_tasks`: the FastestMCP tasks of
      `MCPJobs.FastestMCP.TaskBackend`. It stays empty if you do not use it.

  The tables must be in the same prefix as the Oban tables. Pass
  `prefix: "..."` when Oban uses a prefix other than `"public"`.

  It needs PostgreSQL.
  """

  use Ecto.Migration

  @doc """
  Creates the tables.

  ## Options

    * `:prefix`: the database prefix. The default is `"public"`.
  """
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")
    statuses = Enum.map_join(MCPJobs.Task.statuses(), ", ", &"'#{&1}'")

    create table(:mcp_jobs_tasks, prefix: prefix) do
      add :task_id, :string, null: false
      add :oban_job_id, :bigint
      add :worker, :string, null: false
      add :owner, :map
      add :meta, :map
      add :status, :string, null: false, default: "working"
      add :result, :map
      add :error, :map
      add :progress, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mcp_jobs_tasks, [:task_id], prefix: prefix)
    create index(:mcp_jobs_tasks, [:oban_job_id], prefix: prefix)
    create index(:mcp_jobs_tasks, [:status, :updated_at], prefix: prefix)

    create constraint(:mcp_jobs_tasks, :mcp_jobs_tasks_status_check,
             check: "status IN (#{statuses})",
             prefix: prefix
           )

    create table(:mcp_jobs_fastest_tasks, primary_key: false, prefix: prefix) do
      add :task_id, :string, primary_key: true
      add :session_id, :string
      add :owner_fingerprint, :string
      add :submitted_at, :bigint, null: false
      add :expires_at, :bigint
      add :data, :binary, null: false
    end

    create index(:mcp_jobs_fastest_tasks, [:submitted_at, :task_id], prefix: prefix)
    create index(:mcp_jobs_fastest_tasks, [:session_id, :submitted_at, :task_id], prefix: prefix)
    create index(:mcp_jobs_fastest_tasks, [:expires_at], prefix: prefix)

    :ok
  end

  @doc """
  Drops the tables.

  ## Options

    * `:prefix`: the database prefix. The default is `"public"`.
  """
  @spec down(keyword()) :: :ok
  def down(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")

    drop table(:mcp_jobs_fastest_tasks, prefix: prefix)
    drop table(:mcp_jobs_tasks, prefix: prefix)

    :ok
  end
end
