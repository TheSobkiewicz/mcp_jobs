defmodule ReportServer.Repo.Migrations.AddObanAndMCPO do
  use Ecto.Migration

  def up do
    Oban.Migration.up()
    MCPO.Migration.up()
  end

  def down do
    MCPO.Migration.down()
    Oban.Migration.down()
  end
end
