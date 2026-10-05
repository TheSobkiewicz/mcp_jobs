defmodule DeepThought.Repo.Migrations.AddObanAndMCPJobs do
  use Ecto.Migration

  def up do
    Oban.Migration.up()
    MCPJobs.Migration.up()
  end

  def down do
    MCPJobs.Migration.down()
    Oban.Migration.down()
  end
end
