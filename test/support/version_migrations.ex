defmodule MCPOban.Test.MigrationV1 do
  @moduledoc false
  use Ecto.Migration

  def up, do: MCPOban.Migration.up(prefix: prefix(), version: 1)
  def down, do: MCPOban.Migration.down(prefix: prefix(), version: 1)
end

defmodule MCPOban.Test.MigrationLatest do
  @moduledoc false
  use Ecto.Migration

  def up, do: MCPOban.Migration.up(prefix: prefix())
  def down, do: MCPOban.Migration.down(prefix: prefix(), version: 2)
end
