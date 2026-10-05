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

## Interface simplification (2026-10-02)

- Removed `MCPOban.Worker`. Workers are plain `Oban.Worker` modules. The telemetry handler saves the `perform/1` return value. Trade-off: if the node stops after Oban marks the job completed and before the result is saved, the task is completed with no result.
- Public API is `enqueue/3`, `status/2`, `get/2`, `cancel/2`, `cancelled?/1`.
- `use MCPOban.ExMCP` sets up the ExMCP handler and imports `create_task/4`.

## Clients without tasks (2026-10-02)

Test with the MCP Inspector (TypeScript SDK 1.29, latest protocol `2025-11-25`) showed that it does not know the MCP Tasks extension. Decision: fallback. When a client does not declare the extension, `MCPOban.ExMCP.create_task` waits for the job with `MCPOban.await/2` and returns the tool result directly. On `:wait_timeout` the task is cancelled. Tools use `taskSupport: "optional"`.

## Tools list (2026-10-02)

`use MCPOban.ExMCP, tools: [Worker, {Worker, name: ..., description: ..., input_schema: ...}]` generates `handle_initialize/2`, `handle_list_tools/2` and `handle_call_tool/3`. They are overridable and support `super`.
`use MCPOban.Tool, input_schema: ...` in a worker gives the name, description (from `@moduledoc`) and input schema. Priority: `tools:` options, then `MCPOban.Tool` options, then `@moduledoc`, then defaults. `Code.fetch_docs/1` cannot read docs of modules compiled in the same build, and `mix release` strips docs, so the values are kept at worker compile time.

## Argument checks and installer (2026-10-02)

- Listed tools check the arguments against `input_schema` with `ExMCP.Content.SchemaValidator` (ExJsonSchema, with ExMCP's schema limits) before a job is inserted. Invalid arguments return an `isError` tool result. The schema is compiled at compile time.
- `mix mcp_oban.install` is a plain Mix task (no Igniter): it creates the migration and, with `ex_mcp`, an MCP server module, then prints the next steps.
- Later: explain per-tool job options (idea 2) to the user.

## Oban Pro args_schema (2026-10-05)

The spec excludes Oban Pro features from the MVP. On user request, MCPOban now reads the `args_schema` of an Oban Pro worker (`__args_schema__/0`, undocumented by Pro, same format in Pro 1.5 to 1.7.10) and builds the input schema from it. There is no dependency on Oban Pro. Tests use a fake worker with the same format. Checked once with real Oban Pro 1.7.10: MCPOban and Pro accept and reject the same arguments.

## Review (2026-10-05)

Three independent reviewers. Fixed the findings that at least two reported:
- A read between the Oban ack and the telemetry event lost the result. Now a completed job keeps the task `working` for a grace period (`result_grace_period`, 5 s).
- Unique workers linked two tasks to one job. Now `enqueue/3` returns `{:error, :job_conflict}`.
- A result that is not JSON-safe completed the task with no result. Now the task fails.
- The fallback timeout ignored the cancel result and the `:kill` option.
- The `suspended` job state crashed `get/2` and was not cancelled.
- The Cleaner queue and the deleted-job mapping are now documented.

Reported by one reviewer only, not changed: `enqueue/3` returns an existing task of another owner; a running job of a cancelled task can retry; ExMCP stdio adds `_request_id`/`_meta` to tool arguments; a result with a non-list `"content"` key is passed on as is.

## Second review of the fixes (2026-10-05)

The consensus-review skill (two runs, same results) found problems in the first review fixes. Fixed:
- The `id: nil` conflict clause broke Oban `testing: :inline`. Removed; `conflict?: true` covers real conflicts.
- The rescue for non-JSON results also caught database errors and failed the task for good. The result is now checked with the Postgrex JSON library first; other errors go to the old safety net.
- The error for a non-JSON result showed the whole value to the client. It is now a fixed message; the server log has the exception type only.
- The conflict message now says "A job with the same arguments already exists." Completed jobs within the unique period also conflict; documented.
- Tests for the fallback branches: kill on timeout, a task that finished before the cancel, the conflict message.

Still open (one reviewer each, confirmed by research): ExMCP adds `_request_id`/`_meta` to tool arguments, which also stops Oban `unique:` from finding duplicate calls; `enqueue/3` returns another owner's task for an existing `task_id`; a cancelled task's running job can retry; a non-list `"content"` result is passed on unchanged.

## Open findings fixed (2026-10-05)

- The ExMCP adapter removes `_request_id` and `_meta` from tool arguments before the check and the job. Job args are now the tool arguments only, and Oban `unique:` finds duplicate calls.
- `enqueue/3` returns `{:error, :already_exists}` for an existing `task_id` with another owner or worker.
- When a job attempt fails or snoozes and its task is cancelled, the telemetry handler cancels the job.
- A result is passed on as a tool result only when `"content"` is a list.

## FastestMCP adapter (2026-10-05)

`MCPOban.FastestMCP.add_tools/3` adds one FastestMCP tool per worker. The tool handler inserts the job and waits for it (`MCPOban.await/2`, `:infinity` for background tasks). FastestMCP owns the MCP task, supports Tasks v1 and v2, and handles clients without tasks. On `tasks/cancel`, FastestMCP kills the tool process; a watcher process then calls `MCPOban.cancel/2`. The tool rules moved to `MCPOban.ToolSpec` and are shared with the ExMCP adapter. Checked with the MCP Inspector over HTTP (`examples/report_server/serve_fastest.exs`).

Limit: FastestMCP tasks are in memory, so they do not survive a restart, although the Oban job and the MCPOban task do.
