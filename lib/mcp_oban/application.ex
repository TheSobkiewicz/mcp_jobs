defmodule MCPOban.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    MCPOban.Telemetry.attach()

    if Code.ensure_loaded?(MCPOban.ExMCP.Notifications), do: MCPOban.ExMCP.Notifications.attach()

    Supervisor.start_link([], strategy: :one_for_one, name: MCPOban.Supervisor)
  end
end
