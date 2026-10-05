defmodule MCPJobs.Test.MigrationV1 do
  @moduledoc false
  use Ecto.Migration

  def up, do: MCPJobs.Migration.up(prefix: prefix(), version: 1)
  def down, do: MCPJobs.Migration.down(prefix: prefix(), version: 1)
end

defmodule MCPJobs.Test.MigrationLatest do
  @moduledoc false
  use Ecto.Migration

  def up, do: MCPJobs.Migration.up(prefix: prefix())
  def down, do: MCPJobs.Migration.down(prefix: prefix(), version: 2)
end
