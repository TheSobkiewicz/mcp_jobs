defmodule MCPJobs.Test.TwiceMigration do
  @moduledoc false
  use Ecto.Migration

  def up do
    MCPJobs.Migration.up(prefix: "mcp_jobs_twice")
    MCPJobs.Migration.up(prefix: "mcp_jobs_twice")
  end
end
