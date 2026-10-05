defmodule MCPJobs.MigrationTest do
  use MCPJobs.DataCase

  alias MCPJobs.Test.{MigrationLatest, MigrationV1}

  @moduletag :unsandboxed
  @schema "mcp_jobs_versions"

  setup do
    Repo.query!(~s(CREATE SCHEMA "#{@schema}"))
    on_exit(fn -> Repo.query!(~s(DROP SCHEMA "#{@schema}" CASCADE)) end)
  end

  defp migrate(direction, migrations, opts \\ []) do
    Ecto.Migrator.run(Repo, migrations, direction, [log: false, prefix: @schema] ++ opts)
  end

  defp version do
    %{rows: [[comment]]} =
      Repo.query!(
        "SELECT pg_catalog.obj_description(to_regclass($1), 'pg_class')",
        [~s("#{@schema}".mcp_jobs_tasks)]
      )

    comment
  end

  defp progress_column? do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'mcp_jobs_tasks' AND column_name = 'progress'",
        [@schema]
      )

    rows != []
  end

  defp fastest_table? do
    %{rows: [[found]]} =
      Repo.query!("SELECT to_regclass($1) IS NOT NULL", [~s("#{@schema}".mcp_jobs_fastest_tasks)])

    found
  end

  test "a new install gets the current version" do
    migrate(:up, [{1, MigrationLatest}], all: true)

    assert version() == "3"
    assert progress_column?()
    assert fastest_table?()
  end

  test "an upgrade from version 1 adds the progress column" do
    migrate(:up, [{1, MigrationV1}], all: true)
    assert version() == "1"
    refute progress_column?()

    migrate(:up, [{1, MigrationV1}, {2, MigrationLatest}], all: true)
    assert version() == "3"
    assert progress_column?()
    assert fastest_table?()
  end

  test "a table from before versions counts as version 1" do
    migrate(:up, [{1, MigrationV1}], all: true)
    Repo.query!(~s(COMMENT ON TABLE "#{@schema}".mcp_jobs_tasks IS NULL))

    migrate(:up, [{1, MigrationV1}, {2, MigrationLatest}], all: true)
    assert version() == "3"
    assert progress_column?()
  end

  test "down reverts one version, then drops the table" do
    migrate(:up, [{1, MigrationV1}, {2, MigrationLatest}], all: true)

    migrate(:down, [{1, MigrationV1}, {2, MigrationLatest}], step: 1)
    assert version() == "1"
    refute progress_column?()
    refute fastest_table?()

    migrate(:down, [{1, MigrationV1}, {2, MigrationLatest}], step: 1)

    assert %{rows: [[nil]]} =
             Repo.query!("SELECT to_regclass($1)", [~s("#{@schema}".mcp_jobs_tasks)])
  end
end
