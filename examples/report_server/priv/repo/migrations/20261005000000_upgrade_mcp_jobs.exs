defmodule ReportServer.Repo.Migrations.UpgradeMCPJobs do
  use Ecto.Migration

  def up, do: MCPJobs.Migration.up(version: 3)
  def down, do: MCPJobs.Migration.down(version: 2)
end
