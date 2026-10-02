# MCPOban implementation plan

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
| `MCPOban` | Public API: `enqueue/3`, `status/1`, `cancel/1`, `cancelled?/1` |
| `MCPOban.Task` | Ecto schema for `mcp_oban_tasks` |
| `MCPOban.Repository` | All queries. Each status change is a conditional update (`WHERE status = 'working'`). |
| `MCPOban.Worker` | `use MCPOban.Worker`. You write `run/1`. The wrapper saves the result. |
| `MCPOban.Telemetry` | Listens to Oban events. Sends `[:mcp_oban, :task, ...]` events. |
| `MCPOban.Migration` | `up/0` and `down/0`, used from the host app's migration (the same pattern as Oban) |
| `MCPOban.Cleaner` | Oban worker that deletes old terminal tasks. The host schedules it with Oban Cron. |

### Table `mcp_oban_tasks`

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

- `MCPOban.ExMCP`: implements `ExMCP.Tasks.Store` on the table, plus a helper to call from `handle_call_tool/3`.
- `MCPOban.FastestMCP`: a later step. Its process model conflicts with Oban, so it needs a proxy handler.

## Build order

Each step ends with passing tests.

1. Test setup: Postgres repo, Oban in `:manual` testing mode, `Ecto.Adapters.SQL.Sandbox`
2. Migration and `MCPOban.Task` schema
3. `enqueue/3` with duplicate protection
4. `MCPOban.Worker` with success and retry tests
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
   - (b) Only mark the task `cancelled`, and let the worker check `MCPOban.cancelled?/1`. This is cooperative.
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
