defmodule MCPOban.Test.TwiceMigration do
  @moduledoc false
  use Ecto.Migration

  def up do
    MCPOban.Migration.up(prefix: "mcp_oban_twice")
    MCPOban.Migration.up(prefix: "mcp_oban_twice")
  end
end
