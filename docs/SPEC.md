# MCP ↔ Oban Integration for Elixir

## Goal

Build a small Elixir library that integrates **MCP Tasks** with **Oban jobs**.

The goal is to allow an MCP tool to execute long-running/background work through Oban while exposing the job lifecycle through MCP Tasks.

The library should NOT implement the MCP protocol itself. It should integrate with an existing MCP server implementation (e.g. ExMCP/FastestMCP).

---

## Core concept

Map:

```text
MCP Task ID <-> Oban Job ID
```

Flow:

```text
MCP client
    │
    │ tools/call
    ▼
MCP server
    │
    ▼
MCPOban
    │
    │ Oban.insert()
    ▼
Oban Job
    │
    ▼
Worker
    │
    ├── retry
    ├── success
    ├── failure
    └── cancellation
```

The MCP client receives a task immediately instead of waiting for the Oban job to finish.

---

## Proposed API

The library should provide a simple way to associate an MCP tool with an Oban worker.

Example:

```elixir
defmodule MyApp.MCP.GenerateReport do
  use MCPOban.Tool

  @impl true
  def worker do
    MyApp.Workers.GenerateReport
  end
end
```

Or, if the underlying MCP framework supports a DSL:

```elixir
tool "generate_report",
  worker: MyApp.Workers.GenerateReport
```

The exact API should be adapted to the MCP framework being integrated with.

---

## Task lifecycle

Expected mapping:

| MCP state | Oban state |
|---|---|
| working | available |
| working | scheduled |
| working | executing |
| completed | completed |
| failed | discarded |
| cancelled | cancelled/deleted |

Important:

**An individual Oban retry must NOT cause the MCP task to become failed.**

Example:

```text
attempt 1 → failure
attempt 2 → failure
attempt 3 → success
```

MCP should report:

```text
working → completed
```

Only when Oban has permanently discarded the job should the MCP task become failed.

---

## Task persistence

Do not rely exclusively on in-memory state.

The library should persist the relationship between the MCP task and Oban job.

Possible schema:

```elixir
schema "mcp_oban_tasks" do
  field :task_id, :string
  field :oban_job_id, :integer

  field :status, Ecto.Enum,
    values: [:working, :completed, :failed, :cancelled]

  field :result, :map
  field :error, :map

  timestamps()
end
```

The exact schema should be kept minimal.

`task_id` should have a unique database constraint.

`oban_job_id` should also be indexed.

---

## Result handling

An Oban worker needs a way to return a result that can later be exposed through MCP.

Possible approach:

```elixir
def perform(%Oban.Job{args: args}) do
  result = generate_report(args)

  MCPOban.complete(job, result)

  :ok
end
```

However, prefer a design where workers don't need to know too much about MCP.

For example, the library could provide a wrapper worker:

```elixir
MCPOban.Worker
```

or a result persistence mechanism.

Investigate the cleanest approach.

---

## Cancellation

MCP task cancellation should attempt to cancel the corresponding Oban job.

Example:

```elixir
MCPOban.cancel(task_id)
```

should locate the Oban job and cancel it.

Important edge case:

If the Oban job is already executing, cancelling the Oban job does not necessarily immediately terminate arbitrary Elixir code.

Document this clearly.

If possible, support cooperative cancellation rather than forcibly killing BEAM processes.

---

## Status lookup

The library should provide:

```elixir
MCPOban.status(task_id)
```

returning something like:

```elixir
{:ok, %{
  status: :working,
  progress: nil
}}
```

or:

```elixir
{:ok, %{
  status: :completed,
  result: result
}}
```

and:

```elixir
{:ok, %{
  status: :failed,
  error: error
}}
```

---

## Idempotency

Consider duplicate MCP requests.

The implementation should avoid creating multiple Oban jobs if the same MCP task/request is submitted twice.

Use database constraints where possible rather than relying only on application-level checks.

---

## Telemetry

Emit useful telemetry events, for example:

```text
[:mcp_oban, :task, :started]
[:mcp_oban, :task, :completed]
[:mcp_oban, :task, :failed]
[:mcp_oban, :task, :cancelled]
```

Include metadata such as:

```text
task_id
oban_job_id
worker
duration
```

Do not introduce a custom telemetry system if standard Elixir/Oban telemetry can be reused.

---

## Cleanup

Completed/failed tasks should not live forever.

Provide a configurable cleanup mechanism, e.g.:

```elixir
config :mcp_oban,
  task_retention: :timer.hours(24)
```

Do not delete tasks that are still running.

---

## Architecture

Keep the library independent of any specific MCP implementation as much as possible.

Recommended structure:

```text
lib/
  mcp_oban.ex
  mcp_oban/task.ex
  mcp_oban/repository.ex
  mcp_oban/worker.ex
  mcp_oban/status.ex
  mcp_oban/telemetry.ex
```

Avoid implementing MCP protocol functionality.

The library should provide an adapter/integration layer between:

```text
MCP implementation
        │
        ▼
     MCPOban
        │
        ▼
       Oban
```

---

## MVP scope

Implement only:

1. MCP task ↔ Oban job mapping
2. Task persistence
3. Enqueueing Oban jobs
4. Status mapping
5. Result persistence
6. Retry handling
7. Cancellation
8. Basic telemetry
9. ExUnit tests
10. Documentation/example application

Do NOT implement in MVP:

- MCP protocol
- MCP transport
- OAuth
- MCP Resources
- MCP Prompts
- distributed task coordination
- progress reporting
- Oban Pro-specific functionality
- UI/dashboard

---

## Testing requirements

Test at least:

### Successful job

```text
MCP task created
→ Oban job inserted
→ worker succeeds
→ task becomes completed
→ result is available
```

### Retry

```text
worker fails
→ Oban retries
→ MCP task remains working
→ worker succeeds
→ MCP task becomes completed
```

### Permanent failure

```text
worker fails
→ all retries exhausted
→ Oban discards job
→ MCP task becomes failed
```

### Cancellation

```text
MCP task created
→ cancel requested
→ Oban job cancelled
→ MCP task becomes cancelled
```

### Duplicate request

```text
same task/request submitted twice
→ only one Oban job exists
```

### Race conditions

Test completion/cancellation/retry occurring close together.

Database constraints should be used to protect state transitions where appropriate.

---

## Design principle

The library should be **small and boring**.

Do not duplicate functionality already provided by Oban.

Do not implement another queue.

Do not implement another state-management system unless MCP requires it.

The main value is translating:

```text
MCP Task semantics
        ↓
Oban job semantics
```

while preserving the strengths of both systems.

---

## Definition of Done

A Phoenix/Elixir application using an existing MCP implementation and Oban should be able to expose a long-running tool approximately like:

```elixir
tool "generate_report",
  worker: MyApp.GenerateReportWorker
```

Then:

```text
tools/call
    ↓
MCP Task created
    ↓
Oban Job inserted
    ↓
MCP returns task ID
    ↓
Oban executes worker
    ↓
MCP task becomes completed/failed
    ↓
MCP client retrieves result
```

The resulting library should be usable independently of the example application and should have clear integration points for ExMCP/FastestMCP.
