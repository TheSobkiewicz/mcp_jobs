defmodule MCPO.Migration do
  @moduledoc """
  Creates the `mcpo_tasks` table.

  Call it from a migration in your application:

      defmodule MyApp.Repo.Migrations.AddMCPOTasks do
        use Ecto.Migration

        def up, do: MCPO.Migration.up()
        def down, do: MCPO.Migration.down()
      end

  The table must be in the same prefix as the Oban tables. Pass `prefix: "..."`
  when Oban uses a prefix other than `"public"`.
  """

  use Ecto.Migration

  @doc "Creates the table, its indexes and its constraints."
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")
    statuses = Enum.map_join(MCPO.Task.statuses(), ", ", &"'#{&1}'")

    create_if_not_exists table(:mcpo_tasks, prefix: prefix) do
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

    create_if_not_exists unique_index(:mcpo_tasks, [:task_id], prefix: prefix)
    create_if_not_exists index(:mcpo_tasks, [:oban_job_id], prefix: prefix)
    create_if_not_exists index(:mcpo_tasks, [:status, :updated_at], prefix: prefix)

    create constraint(:mcpo_tasks, :mcpo_tasks_status_check,
             check: "status IN (#{statuses})",
             prefix: prefix
           )

    :ok
  end

  @doc "Drops the table."
  @spec down(keyword()) :: :ok
  def down(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")

    drop_if_exists table(:mcpo_tasks, prefix: prefix)

    :ok
  end
end
