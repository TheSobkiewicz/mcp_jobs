---
name: elixir-mcp-test
description: Test an Elixir MCP server end to end. Starts the server (ExMCP, FastestMCP, Hermes/Anubis, Phoenix plug, or stdio), sends real MCP requests with a bundled client, and reports what passes and fails. It covers tools/list, tool calls, MCP Tasks (2026-07-28 extension and 2025-11-25), polling, cancel, failures, invalid arguments, and clients without tasks. It also checks the database for MCPJobs/Oban servers. Use this skill whenever the user wants to test, smoke test, check, verify, debug or try out an MCP server or MCP tool in an Elixir or Phoenix project, asks "does my MCP server work", wants to call a tool by hand, or changed a tool, adapter, transport or worker and wants to see it working. Also use it to write ExUnit tests for MCP servers.
---

# Test an Elixir MCP server

The goal is evidence: real requests against a real running server, and a short report of what passed and what failed. Unit tests are good, but many MCP bugs live in the transport layer: headers, protocol versions, sessions, time limits, stdout noise. Only a live check finds them.

The bundled client is `scripts/mcp_probe.py` (Python standard library only, no install). Run it with `--help` once to see all options.

```bash
PROBE=<this skill dir>/scripts/mcp_probe.py
python3 $PROBE --url http://localhost:4000/ smoke
```

If `python3` fails with "No version is set for command python3" (asdf), use `/usr/bin/python3`.

## 1. Find the server

Search the project to learn the library, the transport, the port and the path:

```bash
grep -rnE "ExMCP\.HttpPlug|ExMCP\.Server|FastestMCP\.(server|streamable_http_child_spec|start_server)|Hermes\.Server|Anubis\.Server|StreamableHTTP|transport: :stdio" lib config *.exs examples 2>/dev/null
```

Typical results:

| Library | HTTP endpoint | Start command |
| --- | --- | --- |
| ExMCP with `Plug.Cowboy.http(ExMCP.HttpPlug, ...)` | `http://localhost:PORT/` | a script, or the app supervisor |
| ExMCP in Phoenix (`forward "/mcp", ExMCP.HttpPlug`) | `http://localhost:4000/mcp` | `mix phx.server` |
| FastestMCP `streamable_http_child_spec` | `http://localhost:PORT/mcp` | a script, or the app supervisor |
| Hermes / Anubis `StreamableHTTP` | the path of the `forward` | `mix phx.server` |
| stdio | none | `--stdio "mix run --no-halt start_stdio.exs"` |

Also read the tool modules. You need one valid set of arguments and one invalid set (wrong type, missing required field) for each tool you test. For MCPJobs, the tools are the Oban workers in the `tools:` list or `add_tools/3`.

## 2. Start the server

- Check the port first: `lsof -nP -iTCP:PORT -sTCP:LISTEN`. If the user already runs a server there, do not stop it. Start your own copy on another port, for example `PORT=4100`.
- Check what the server needs: Postgres (`pg_isready`), `mix ecto.create`, `mix ecto.migrate`.
- Start it in the background and write its log to a file, so you can read errors later:

  ```bash
  PORT=4100 nohup mix run --no-halt serve.exs > $LOG 2>&1 &
  for i in $(seq 1 60); do curl -s -o /dev/null localhost:4100/ && break; sleep 1; done; tail -5 $LOG
  ```

  A script that ends with `Process.sleep(:infinity)` does not need `--no-halt`. The first start can compile for a long time, so wait.
- Remember the PIDs you started. You stop only these at the end.

## 3. Run the generic checks

```bash
python3 $PROBE --url URL smoke --tool TOOL --args '{"valid":"args"}' --bad-args '{"valid":5}'
```

`auto` mode picks the protocol. It tries modern (2026-07-28, stateless, `_meta` in each request), then 2025-11-25 with a session and the `tasks` capability, then 2025-11-25 without tasks. It prefers a mode where the server supports tasks. stderr shows which mode it chose. Force a mode with `--mode modern|tasks-2025|plain`.

The smoke checks: tools/list is not empty; each tool has a description and an object input schema; an unknown tool gives an error; an unknown task id gives an error; the tool with valid arguments completes; the tool with invalid arguments is rejected.

## 4. Test the task flow

Test each case that applies. Each command prints progress to stderr and the final JSON to stdout.

| Case | Command | Expected |
| --- | --- | --- |
| Task completes | `call TOOL --args '{...}' --wait` | `completed` with the result |
| Cancel | `call TOOL --args '{...}' --wait --cancel-after 1` | `cancelled` |
| Tool fails | `call TOOL --args '<args that make it fail>' --wait` | `failed`, with a safe error message only |
| Client without tasks | `--mode plain call TOOL --args '{...}'` | direct result, after the job finishes |
| Each protocol | repeat with `--mode modern` and `--mode tasks-2025` | same behavior |
| Step by step | `call TOOL` (no wait), then `get ID`, `cancel ID`, `wait ID` | the saved session or mode is reused |
| Any other method | `raw METHOD --params '{...}'` | |

Run all modes the server claims to support. A server can work in one protocol and break in another.

### Extra checks for MCPJobs / Oban servers

The MCP task status must follow the Oban job. So also check the database (find the repo database in `config/`):

```bash
psql -d DB -Atc "select id, state, attempt, max_attempts, args from oban_jobs order by id desc limit 5"
psql -d DB -Atc "select id, status, oban_job_id from mcp_jobs_tasks order by inserted_at desc limit 5"
```

- **Retry does not fail the task.** Use a worker that fails on the first attempt. The task stays `working` while Oban retries, and it then completes. `attempt` in `oban_jobs` is greater than 1.
- **Failure only on discard.** A task is `failed` only after the last attempt. The time to `failed` is about `max_attempts × backoff`.
- **Safe errors.** A failed task shows only the error `"message"`. Other fields of the worker error (internal data) must not appear.
- **Cancel reaches Oban.** After `tasks/cancel`, the Oban job state is `cancelled` (or the job stops at its next `MCPJobs.cancelled?/1` check).
- **Invalid arguments start no job.** The number of rows in `oban_jobs` does not change. ExMCP returns `isError` at once. FastestMCP creates a task that fails at once.
- **Progress.** While the task works, `statusMessage` changes, for example `"Thinking (2/6)"`.

## 5. Report

Keep the report short. Use this form:

```
Server: <library>, <URL or stdio command>, modes tested: <modes>

| Check | Mode | Result | Detail |
| --- | --- | --- | --- |
| ... | modern | PASS | completed in 6.1 s |
| ... | tasks-2025 | FAIL | task stayed working after 120 s |

Problems found:
1. <what fails, the request that shows it, the related log line>
```

For a FAIL, include the command to run it again and the relevant lines from the server log. Say which results are bugs and which are only notes (for example, an unusual but valid error code).

## 6. Clean up

Stop only the processes you started (`kill <pid>`; a `mix run` child can need `pkill -f "PORT=4100"` or `lsof -ti :4100 | xargs kill`). Leave the user's servers alone. Do not delete database rows unless the user asks.

## Known problems to check first

- **Port in use**: `:eaddrinuse` in the log. Another server runs on the port.
- **Two servers, one queue**: two nodes that use the same database and Oban queue can run each other's jobs. Polling with `tasks/get` still works (the state is in the database), but ExMCP sends `notifications/tasks` only on the node that ran the job.
- **stdio noise**: a stdio server must write only JSON-RPC to stdout. The client shows `WARNING: non-JSON line on stdout` for `IO.puts` or Logger output. Send logs to stderr.
- **Time limits**: a client without tasks waits for the job. Each limit in the chain must be longer than the one before it (ExMCP: `wait_timeout` < `handler_call_timeout` < Cowboy `idle_timeout`; FastestMCP: `wait_timeout` < `stream_request_timeout_ms`). Use `--timeout` on the client for long jobs.
- **Modern headers**: modern requests need `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` headers. The client sends them. Error `-32020` means a header does not match the body.
- **FastestMCP modern tasks**: FastestMCP gives modern clients tasks only when the server declares the `io.modelcontextprotocol/tasks` extension. Without it, a modern call returns the result directly and `tasks/get` gives `-32601`.

## ExUnit tests

To turn a live check into a test, read `references/exunit.md`. It shows in-process clients for ExMCP (BEAM and HTTP transport) and FastestMCP, and how to run Oban jobs in tests.
