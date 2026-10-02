alias MCPO.Test.Repo

_ = Ecto.Adapters.Postgres.storage_up(Repo.config())
{:ok, _} = Repo.start_link()
Ecto.Migrator.run(Repo, [{0, MCPO.Test.Migration}], :up, all: true, log: false)
{:ok, _} = Oban.start_link(repo: Repo, testing: :manual)
Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

ExUnit.start()
