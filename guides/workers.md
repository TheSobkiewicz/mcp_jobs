# Workers

A worker is a plain `Oban.Worker`. It does not need to know about MCP:

```elixir
defmodule MyApp.Workers.GenerateReport do
  use Oban.Worker, queue: :reports, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"report_id" => report_id}}) do
    {:ok, %{"url" => MyApp.Reports.generate(report_id)}}
  end
end
```

The return value of `perform/1` becomes the task result:

- `{:ok, map}` completes the task and saves the map as the result.
- `{:ok, value}` saves `%{"value" => value}`.
- `:ok` completes the task with no result.
- `{:error, reason}` makes Oban retry the job. The task stays `working`.

The result is stored as JSON, so atom keys come back as strings. The result must be JSON-safe: for example, no tuples or PIDs. A struct such as `DateTime` is saved as `%{"value" => ...}`.

> **Note:** Oban marks the job `completed` first, and then MCPJobs saves the result from the Oban telemetry event. Between these two steps the task stays `working`. If the result is not saved within 5 seconds (for example, the node stopped), the task becomes `completed` with no result. Change the time with `config :mcp_jobs, result_grace_period: 5_000`.
>
> A result that cannot be saved as JSON makes the task `failed`.
>
> When Oban deletes a job before MCPJobs sees its final state (for example, the Pruner removed it), the task becomes `cancelled`. Keep the Pruner `max_age` longer than the time clients take to read a result.
>
> Workers with Oban `unique:` options: a duplicate job is rejected with `{:error, :job_conflict}`. Two tasks never share one job. With Oban's default unique states, a job that has already completed within the unique period also counts as a duplicate.

## Progress

A long worker can report its progress:

```elixir
def perform(%Oban.Job{args: %{"steps" => steps}} = job) do
  for step <- 1..steps do
    do_step(step)
    MCPJobs.progress(job, step, steps, "Wrote section #{step}")
  end

  {:ok, %{"sections" => steps}}
end
```

`MCPJobs.progress(job, current, total \\ nil, message \\ nil)` saves the progress while the task is `working`. `current` should grow. Clients see it:

- With ExMCP, `tasks/get` shows it as `statusMessage`, for example `"Wrote section 2 (2/5)"`. A client without tasks gets progress notifications when it sent a progress token.
- With FastestMCP, it becomes the progress of the FastestMCP task, and FastestMCP sends it to the client. FastestMCP also sends its own task notifications. A task that a durable backend kept after a restart has no tool process, so its listeners get no notifications; `tasks/get` still shows its state.
- `MCPJobs.status/2` returns it as `%{status: :working, progress: %{"current" => 2, "total" => 5, "message" => "..."}}`.

The adapters check for new progress at their `:interval`.

## Errors

When a job fails for good, the task error is:

```elixir
%{"message" => "The task failed.", "details" => "...the exception or the returned reason..."}
```

MCP clients get only `"message"`. The `"details"` can hold internal data (secrets, database values, stack traces), so they stay on the server: in `MCPJobs.status/2` and in the `mcp_jobs_tasks` table.

To choose the message that clients see, return it from `perform/1`:

```elixir
{:error, %{"message" => "The report period is empty."}}
```

## Cancellation

`MCPJobs.cancel/2` sets the task to `cancelled` at once.

- **The job waits to run:** Oban cancels the job.
- **The job is running:** Oban does not stop it. The BEAM cannot safely stop any code at any point, so the worker must stop by itself. A long worker should check `MCPJobs.cancelled?/1` between steps:

  ```elixir
  def perform(%Oban.Job{} = job) do
    Enum.reduce_while(steps(), :ok, fn step, :ok ->
      if MCPJobs.cancelled?(job) do
        {:halt, {:cancel, :mcp_task_cancelled}}
      else
        do_step(step)
        {:cont, :ok}
      end
    end)
  end
  ```

  If the worker does not stop, it runs to the end, but its result is not saved. The task stays `cancelled`. If the attempt fails or snoozes, MCPJobs cancels the job, so Oban does not run it again.

- **Kill the job:** `MCPJobs.cancel(task_id, kill: true)` makes Oban kill a running job. The process stops at once and cannot clean up.

With ExMCP, use `use MCPJobs.ExMCP, task_store_opts: [kill: true]` to kill running jobs on `tasks/cancel`.

## Races

Each status change is one database update with the condition `WHERE status = 'working'`. The first change wins, and a terminal status never changes. For example, if a job completes while a client cancels it, the task is either `completed` or `cancelled`, never both.
