defmodule MCPJobs.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    MCPJobs.Telemetry.attach()

    if Code.ensure_loaded?(MCPJobs.ExMCP.Notifications), do: MCPJobs.ExMCP.Notifications.attach()

    Supervisor.start_link([], strategy: :one_for_one, name: MCPJobs.Supervisor)
  end
end
