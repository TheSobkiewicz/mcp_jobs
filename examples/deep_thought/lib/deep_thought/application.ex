defmodule DeepThought.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      DeepThought.Repo,
      {Oban, Application.fetch_env!(:deep_thought, Oban)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: DeepThought.Supervisor)
  end
end
