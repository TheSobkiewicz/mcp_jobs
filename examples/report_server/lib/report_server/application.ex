defmodule ReportServer.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      ReportServer.Repo,
      {Oban, Application.fetch_env!(:report_server, Oban)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ReportServer.Supervisor)
  end
end
