defmodule MCPJobs.Test.PrefixMigration do
  @moduledoc false
  use Ecto.Migration

  def up, do: MCPJobs.Migration.up(prefix: prefix())
  def down, do: MCPJobs.Migration.down(prefix: prefix())
end
