# MCPO implementation plan

## Facts that shape the design

- MCP Tasks exist in two versions:
  - **v1** (spec 2025-11-25): `tasks/get`, `tasks/result`, `tasks/list`, `tasks/cancel`.
  - **v2** (spec 2026-07-28, an extension): `tasks/get` returns the result, plus `tasks/cancel` and `tasks/update`.
- The MCP server makes the task ID.
- ExMCP 1.5 supports v2 through a pluggable `ExMCP.Tasks.Store` behaviour. This is a clean place to plug in.
- FastestMCP 0.3 runs task handlers in its own processes and kills them on cancel. Only its storage is pluggable.
- Oban reports every job result with `[:oban, :job, :stop | :exception]` telemetry. The `state` field tells a retry (`:failure`) apart from a final failure (`:discard`).
- `Oban.cancel_job/1` also kills a job that is running.

## Core (no MCP dependency)

| Module | Job |
|---|---|
| `MCPO` | Public API: `enqueue/3`, `status/1`, `cancel/1`, `cancelled?/1` |
| `MCPO.Task` | Ecto schema for `mcpo_tasks` |
| `MCPO.Repository` | All queries. Each status change is a conditional update (`WHERE status = 'working'`). |
| `MCPO.Worker` | `use MCPO.Worker`. You write `run/1`. The wrapper saves the result. |
| `MCPO.Telemetry` | Listens to Oban events. Sends `[:mcpo, :task, ...]` events. |
| `MCPO.Migration` | `up/0` and `down/0`, used from the host app's migration (the same pattern as Oban) |
| `MCPO.Cleaner` | Oban worker that deletes old terminal tasks. The host schedules it with Oban Cron. |

### Table `mcpo_tasks`

- `task_id`: string, unique index
- `oban_job_id`: bigint, index, no foreign key (Oban's pruner deletes jobs)
- `worker`: string
- `owner`: map, for auth context
- `status`: `working | completed | failed | cancelled`
- `result`, `error`: map
- timestamps

### How the main flows work

1. **Enqueue:** one transaction inserts the task row and the Oban job. The `task_id` goes into `job.meta`.
   - A duplicate `task_id` hits the unique index. Then we return the existing task and insert no second job.
2. **Success:** the wrapper calls `run/1` and gets `{:ok, result}`. It saves the result and sets `completed`.
3. **Retry:** we change nothing, and the task stays `working`.
4. **Final failure:** the telemetry handler sees `state: :discard` and sets `failed` with the error.
5. **Cancel:** set `cancelled` with a conditional update, then cancel the Oban job.
6. **Races:** every change uses `WHERE status = 'working'`, so the first change wins and later changes do nothing.
7. **Safety net:** `status/1` also checks the Oban job. If the job is discarded, cancelled, or gone but the task still shows `working`, it fixes the task. This covers telemetry handlers that crash or detach.
8. **Repo:** we use Oban's configured repo (`Oban.config/1`), so the host does not need extra config.

## Adapters (optional dependencies)

- `MCPO.ExMCP`: implements `ExMCP.Tasks.Store` on the table, plus a helper to call from `handle_call_tool/3`.
- `MCPO.FastestMCP`: a later step. Its process model conflicts with Oban, so it needs a proxy handler.

## Build order

Each step ends with passing tests.

1. Test setup: Postgres repo, Oban in `:manual` testing mode, `Ecto.Adapters.SQL.Sandbox`
2. Migration and `MCPO.Task` schema
3. `enqueue/3` with duplicate protection
4. `MCPO.Worker` with success and retry tests
5. Telemetry handler with final failure tests
6. `cancel/1` and `cancelled?/1`
7. Race tests: complete versus cancel, discard versus cancel
8. `status/1` with the safety net
9. Cleaner
10. ExMCP adapter and example app
11. README

## Open questions

1. **Running job on cancel:** `Oban.cancel_job` kills the process. Pick one:
   - (a) Kill the process.
   - (b) Only mark the task `cancelled`, and let the worker check `MCPO.cancelled?/1`. This is cooperative.
   - (c) Cooperative by default, with an option to kill.
2. **MCP version:** support only v2 (current spec, supported by ExMCP), or v1 too?
3. **FastestMCP:** include it in the MVP, or add it after the ExMCP adapter works?

## Decisions (2026-10-02)

1. Cancel is cooperative by default. `cancel(task_id, kill: true)` also kills a running job.
2. Only MCP Tasks v2 (spec 2026-07-28).
3. FastestMCP comes after the ExMCP adapter.

## Progress

- Done: steps 1 to 9 (core library and its tests).
- Done: step 10 (ExMCP adapter, `examples/report_server`) and step 11 (README).
- Next: FastestMCP adapter.

## Interface simplification (2026-10-02)

- Removed `MCPO.Worker`. Workers are plain `Oban.Worker` modules. The telemetry handler saves the `perform/1` return value. Trade-off: if the node stops after Oban marks the job completed and before the result is saved, the task is completed with no result.
- Public API is `enqueue/3`, `status/2`, `get/2`, `cancel/2`, `cancelled?/1`.
- `use MCPO.ExMCP` sets up the ExMCP handler and imports `create_task/4`.

## Clients without tasks (2026-10-02)

Test with the MCP Inspector (TypeScript SDK 1.29, latest protocol `2025-11-25`) showed that it does not know the MCP Tasks extension. Decision: fallback. When a client does not declare the extension, `MCPO.ExMCP.create_task` waits for the job with `MCPO.await/2` and returns the tool result directly. On `:wait_timeout` the task is cancelled. Tools use `taskSupport: "optional"`.
