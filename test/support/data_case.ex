defmodule MCPOban.DataCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias MCPOban.Test.Repo

  using do
    quote do
      use Oban.Testing, repo: MCPOban.Test.Repo

      import Ecto.Query
      import MCPOban.DataCase

      alias MCPOban.Test.Repo
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    :ok
  end

  @doc "Runs all jobs, including retries, until no job is left to run."
  def drain do
    Oban.drain_queue(queue: :default, with_scheduled: true, with_recursion: true)
  end

  @doc "Sends `{:telemetry, event, measurements, metadata}` to the test process for MCPOban events."
  def attach_telemetry do
    test_pid = self()
    handler_id = "test-#{inspect(make_ref())}"

    events =
      for event <- [:started, :completed, :failed, :cancelled], do: [:mcp_oban, :task, event]

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
