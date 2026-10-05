defmodule ReportServer.Repo.Migrations.UpgradeMCPOban do
  use Ecto.Migration

  def up, do: MCPOban.Migration.up(version: 3)
  def down, do: MCPOban.Migration.down(version: 2)
end
