defmodule ReportServer.Repo.Migrations.AddObanAndMCPOban do
  use Ecto.Migration

  def up do
    Oban.Migration.up()
    MCPOban.Migration.up()
  end

  def down do
    MCPOban.Migration.down()
    Oban.Migration.down()
  end
end
