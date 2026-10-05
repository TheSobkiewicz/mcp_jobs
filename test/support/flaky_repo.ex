defmodule MCPJobs.Test.FlakyRepo do
  @moduledoc false

  # The first update_all in the calling process raises like a lost database
  # connection. Later calls go to the test repo.
  def update_all(queryable, updates, opts) do
    if Process.get(:flaky_repo_failed) do
      MCPJobs.Test.Repo.update_all(queryable, updates, opts)
    else
      Process.put(:flaky_repo_failed, true)
      raise DBConnection.ConnectionError, "connection not available"
    end
  end
end
