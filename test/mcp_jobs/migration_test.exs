defmodule MCPJobs.MigrationTest do
  use MCPJobs.DataCase

  alias MCPJobs.Test.PrefixMigration

  @moduletag :unsandboxed
  @schema "mcp_jobs_prefix"

  setup do
    Repo.query!(~s(CREATE SCHEMA "#{@schema}"))
    on_exit(fn -> Repo.query!(~s(DROP SCHEMA "#{@schema}" CASCADE)) end)
  end

  defp migrate(direction) do
    Ecto.Migrator.run(Repo, [{1, PrefixMigration}], direction,
      all: true,
      log: false,
      prefix: @schema
    )
  end

  defp table?(table) do
    %{rows: [[found]]} =
      Repo.query!("SELECT to_regclass($1) IS NOT NULL", [~s("#{@schema}".#{table})])

    found
  end

  test "up creates both tables in the prefix, and down drops them" do
    migrate(:up)

    assert table?("mcp_jobs_tasks")
    assert table?("mcp_jobs_fastest_tasks")

    assert_raise Postgrex.Error, ~r/mcp_jobs_tasks_status_check/, fn ->
      Repo.query!(
        ~s[INSERT INTO "#{@schema}".mcp_jobs_tasks (task_id, worker, status, inserted_at, updated_at) VALUES ('t', 'W', 'unknown', now(), now())]
      )
    end

    migrate(:down)

    refute table?("mcp_jobs_tasks")
    refute table?("mcp_jobs_fastest_tasks")
  end
end
