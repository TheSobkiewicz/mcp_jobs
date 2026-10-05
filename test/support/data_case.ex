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

  # A test tagged :unsandboxed uses real pool connections, as in production.
  # Use it when the test kills processes that may be in the middle of a query:
  # in the shared sandbox, that breaks the one connection of the test.
  setup tags do
    if tags[:unsandboxed] do
      Sandbox.mode(Repo, :auto)

      on_exit(fn ->
        Repo.delete_all(MCPOban.Task)
        Repo.delete_all(Oban.Job)
        Sandbox.mode(Repo, :manual)
      end)
    else
      pid = Sandbox.start_owner!(Repo, shared: not tags[:async])
      on_exit(fn -> Sandbox.stop_owner(pid) end)
    end

    :ok
  end

  @doc "Runs all jobs, including retries, until no job is left to run."
  def drain do
    Oban.drain_queue(queue: :default, with_scheduled: true, with_recursion: true)
  end

  @doc """
  Runs jobs in a separate process until the returned function is called.
  Use it when the code under test waits for a job.
  """
  def run_jobs_in_background do
    pid = spawn_link(&drain_loop/0)

    fn ->
      ref = Process.monitor(pid)
      send(pid, :stop)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    end
  end

  defp drain_loop do
    receive do
      :stop -> :ok
    after
      20 ->
        drain()
        drain_loop()
    end
  end

  @doc "Calls `fun` until it returns a truthy value, for at most `timeout` milliseconds."
  def eventually(fun, timeout \\ 2_000) do
    cond do
      result = fun.() ->
        result

      timeout <= 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(20)
        eventually(fun, timeout - 20)
    end
  end

  @doc "Sends `{:telemetry, event, measurements, metadata}` to the test process for MCPOban events."
  def attach_telemetry do
    test_pid = self()
    handler_id = "test-#{inspect(make_ref())}"

    events =
      for event <- [:started, :completed, :failed, :cancelled, :progress],
          do: [:mcp_oban, :task, event]

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
