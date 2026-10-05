defmodule MCPJobs.Migration do
  @moduledoc """
  Creates and upgrades the `mcp_jobs_tasks` table.

  Call it from a migration in your application:

      defmodule MyApp.Repo.Migrations.AddMCPJobsTasks do
        use Ecto.Migration

        def up, do: MCPJobs.Migration.up()
        def down, do: MCPJobs.Migration.down()
      end

  The table has a version. `up/1` runs only the versions that the database does
  not have yet, and records the new version as a comment on the table. When a new
  MCPJobs release changes the table, add a new migration that calls `up/1` again:

      defmodule MyApp.Repo.Migrations.UpgradeMCPJobsTasks do
        use Ecto.Migration

        def up, do: MCPJobs.Migration.up(version: 3)
        def down, do: MCPJobs.Migration.down(version: 2)
      end

  Versions:

    * 1: the table, its indexes and the status constraint.
    * 2: the `progress` column.
    * 3: the `mcp_jobs_fastest_tasks` table, for `MCPJobs.FastestMCP.TaskBackend`.

  The table must be in the same prefix as the Oban tables. Pass `prefix: "..."`
  when Oban uses a prefix other than `"public"`.

  It needs PostgreSQL. It is safe to run more than once.
  """

  use Ecto.Migration

  @current_version 3

  @doc """
  Upgrades the table to `:version` (default: the current version).

  ## Options

    * `:version`: the version to upgrade to.
    * `:prefix`: the database prefix. The default is `"public"`.
  """
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")
    target = Keyword.get(opts, :version, @current_version)
    initial = migrated_version(prefix: prefix)

    if initial < target do
      Enum.each((initial + 1)..target//1, &change(&1, :up, prefix))
      record_version(prefix, target)
    end

    :ok
  end

  @doc """
  Reverts the table down to before `:version` (default: 1, which drops the table).

  ## Options

    * `:version`: the lowest version to revert.
    * `:prefix`: the database prefix. The default is `"public"`.
  """
  @spec down(keyword()) :: :ok
  def down(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")
    target = Keyword.get(opts, :version, 1)
    initial = migrated_version(prefix: prefix)

    if initial >= target do
      Enum.each(initial..target//-1, &change(&1, :down, prefix))
      if target > 1, do: record_version(prefix, target - 1)
    end

    :ok
  end

  @doc """
  Returns the version of the table in the database: 0 when there is no table.

  A table from before versions existed counts as version 1.
  """
  @spec migrated_version(keyword()) :: non_neg_integer()
  def migrated_version(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")
    table = ~s("#{prefix}".mcp_jobs_tasks)

    query = """
    SELECT to_regclass('#{table}') IS NOT NULL,
           pg_catalog.obj_description(to_regclass('#{table}'), 'pg_class')
    """

    case repo().query!(query, [], log: false) do
      %{rows: [[false, _comment]]} -> 0
      %{rows: [[true, nil]]} -> 1
      %{rows: [[true, comment]]} -> String.to_integer(comment)
    end
  end

  defp change(1, :up, prefix) do
    statuses = Enum.map_join(MCPJobs.Task.statuses(), ", ", &"'#{&1}'")

    create_if_not_exists table(:mcp_jobs_tasks, prefix: prefix) do
      add :task_id, :string, null: false
      add :oban_job_id, :bigint
      add :worker, :string, null: false
      add :owner, :map
      add :meta, :map
      add :status, :string, null: false, default: "working"
      add :result, :map
      add :error, :map

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists unique_index(:mcp_jobs_tasks, [:task_id], prefix: prefix)
    create_if_not_exists index(:mcp_jobs_tasks, [:oban_job_id], prefix: prefix)
    create_if_not_exists index(:mcp_jobs_tasks, [:status, :updated_at], prefix: prefix)

    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'mcp_jobs_tasks_status_check'
          AND conrelid = '"#{prefix}"."mcp_jobs_tasks"'::regclass
      ) THEN
        ALTER TABLE "#{prefix}"."mcp_jobs_tasks"
          ADD CONSTRAINT mcp_jobs_tasks_status_check CHECK (status IN (#{statuses}));
      END IF;
    END
    $$;
    """
  end

  defp change(1, :down, prefix) do
    drop_if_exists table(:mcp_jobs_tasks, prefix: prefix)
  end

  defp change(2, :up, prefix) do
    alter table(:mcp_jobs_tasks, prefix: prefix) do
      add_if_not_exists :progress, :map
    end
  end

  defp change(2, :down, prefix) do
    alter table(:mcp_jobs_tasks, prefix: prefix) do
      remove_if_exists :progress, :map
    end
  end

  defp change(3, :up, prefix) do
    create_if_not_exists table(:mcp_jobs_fastest_tasks, primary_key: false, prefix: prefix) do
      add :task_id, :string, primary_key: true
      add :session_id, :string
      add :owner_fingerprint, :string
      add :submitted_at, :bigint, null: false
      add :expires_at, :bigint
      add :data, :binary, null: false
    end

    create_if_not_exists index(:mcp_jobs_fastest_tasks, [:submitted_at, :task_id], prefix: prefix)

    create_if_not_exists index(:mcp_jobs_fastest_tasks, [:session_id, :submitted_at, :task_id],
                           prefix: prefix
                         )

    create_if_not_exists index(:mcp_jobs_fastest_tasks, [:expires_at], prefix: prefix)
  end

  defp change(3, :down, prefix) do
    drop_if_exists table(:mcp_jobs_fastest_tasks, prefix: prefix)
  end

  defp record_version(prefix, version) do
    execute ~s(COMMENT ON TABLE "#{prefix}".mcp_jobs_tasks IS '#{version}')
  end
end
