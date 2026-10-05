# MCPJobs

A small Elixir library that connects MCP Tasks to Oban jobs. An MCP tool puts its work in an Oban job and gets back a task ID immediately. The MCP task status follows the Oban job state.

## Key rules

- Do not implement the MCP protocol or transport. Integrate with an existing MCP server (ExMCP, FastestMCP).
- Keep the library small and simple. Do not repeat what Oban already does.
- An Oban retry must not make the MCP task fail. The task fails only when Oban discards the job.
- Use database constraints for idempotency and state transitions. Do not rely only on application checks.
- Do not depend on Oban Pro. Only `MCPJobs.ArgsSchema` reads Oban Pro data (`__args_schema__/0`), with no compile-time dependency.
- Keep the scope small. Ask before you add a large feature.

## Toolchain

- Versions are managed with asdf through `.tool-versions` in the project root: Erlang 27.3.4, Elixir 1.19.5-otp-27.
- The global `~/.tool-versions` points to Erlang 27.1.1, which is not installed. Always run commands from the project root so the local pin applies.

## Commands

- `mix deps.get`: install dependencies
- `mix compile --warnings-as-errors`: compile
- `mix test`: run all tests; `mix test path/to/file_test.exs:LINE` runs a single test
- `mix format`: format the code. Run it before finishing any change.
- `mix mcp_jobs.install` (in a host app): creates the MCPJobs migration and an MCP server module.

## Conventions

- Follow standard Elixir style. `mix format` is the source of truth.
- Pattern match in function heads instead of nesting conditionals. Return `{:ok, value}` / `{:error, reason}` tuples from fallible functions.
- Do not use dot access (`user.name`) when you can pattern match the value in the function head (`def greet(%User{name: name})`).
- Add comments only when the code does not explain itself. Keep comments as short as possible.
- Every public module gets a `@moduledoc`, and public functions get `@doc` and `@spec`.
- Put tests in `test/`, mirroring the `lib/` structure. Add or update tests with every behavior change.
- Don't add dependencies without asking first.

## Responses

- Write in ASD-STE100 Simplified Technical English: short sentences, simple words, one instruction per sentence, active voice.
- Keep responses short.
- Do not use jargon or technical terms unless they are necessary.

## Architecture

- `MCPJobs`: public API (`enqueue/3`, `status/2`, `get/2`, `await/2`, `cancel/2`, `cancelled?/1`, `progress/4`). Keep it this small. `complete/3`, `fail/3` and `transition/4` are `@doc false`, for adapters only.
- `MCPJobs.Repository`: all queries. A status change is a conditional update (`WHERE status = 'working'`), so the first change wins.
- Workers are plain `Oban.Worker` modules. `MCPJobs.Telemetry` saves the `perform/1` return value as the task result. `use MCPJobs.Tool` in a worker is optional: it keeps `@moduledoc` and the tool options in `__mcp_jobs_tool__/0` at compile time, because `Code.fetch_docs/1` does not work during compilation and releases strip docs.
- `MCPJobs.Telemetry`: listens to Oban job events and sets `completed`, `failed` or `cancelled`. It also sends `[:mcp_jobs, :task, ...]` events, including `:progress`. The metadata has `:oban`, the Oban instance name.
- `MCPJobs.Application`: attaches the telemetry handlers. It starts no processes.
- `MCPJobs.ExMCP.Notifications`: a telemetry handler that publishes `notifications/tasks` for tasks of `MCPJobs.ExMCP.Store` (meta `"ex_mcp" => true`) to ExMCP listeners.
- `MCPJobs.ExMCP` and `MCPJobs.ExMCP.Store`: the ExMCP adapter. `use MCPJobs.ExMCP, tools: [Worker, ...]` generates the handler callbacks. `ex_mcp` is an optional dependency, so both modules are inside `if Code.ensure_loaded?(...)`. Keep them out of the core modules.
- `MCPJobs.FastestMCP`: the FastestMCP adapter (`add_tools/3`). Each tool inserts a job and waits for it; FastestMCP owns the MCP task. A watcher process cancels the MCPJobs task when FastestMCP kills the waiting tool. Also optional and inside `if Code.ensure_loaded?(...)`.
- `MCPJobs.FastestMCP.TaskBackend`: a FastestMCP `TaskBackend` on the `mcp_jobs_fastest_tasks` table. After a restart it keeps tasks of MCPJobs tools working and shows the MCPJobs task state, using `FastestMCP.ResultNormalizer.normalize_tool/1` for results.
- `MCPJobs.ToolSpec`: builds the tool list (name, description, input schema) for both adapters.
- `examples/deep_thought`: an example app (Deep Thought computes 42). Run `mix run demo.exs` in it to check the full flow with real Oban queues: progress, notifications, retry, cancel and a failed task.
- MCPJobs uses the repo of the Oban instance (`Oban.config/1`) and has no repo config of its own.
- Tests that kill processes in the middle of a query use `@tag :unsandboxed` (see `test/support/data_case.ex`).
- `MCPJobs.Migration` creates both tables in one step, with no versions (nothing is released yet). Add versions only when a release must change existing tables.
- Tests need a local Postgres. `test/test_helper.exs` drops and creates the `mcp_jobs_test` database on each run and runs the migrations, so migration changes always apply.
