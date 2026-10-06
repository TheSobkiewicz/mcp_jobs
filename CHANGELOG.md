# Changelog

## 0.1.0 (2026-10-06)

The first release.

- Run MCP tool calls as Oban jobs. The MCP task status follows the Oban job state, and a retry does not fail the task.
- Core API without an MCP library: `MCPJobs.enqueue/3`, `status/2`, `get/2`, `await/2`, `cancel/2`, `cancelled?/1`, and `progress/4`.
- ExMCP adapter (`use MCPJobs.ExMCP, tools: [...]`): MCP Tasks (`2026-07-28` extension), push notifications, and a direct result for clients without tasks.
- FastestMCP adapter (`MCPJobs.FastestMCP.add_tools/3`) and a durable FastestMCP task backend.
- Tools from workers: the description from `@moduledoc`, and the input schema from the options or from an Oban Pro `args_schema`. Arguments are checked before a job starts.
- Safe client error messages, duplicate protection, and task owners.
- Telemetry events, `MCPJobs.Cleaner`, and `mix mcp_jobs.install` (with `--phoenix`).
