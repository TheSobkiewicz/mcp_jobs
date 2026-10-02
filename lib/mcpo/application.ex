defmodule MCPO.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    MCPO.Telemetry.attach()

    Supervisor.start_link([], strategy: :one_for_one, name: MCPO.Supervisor)
  end
end
