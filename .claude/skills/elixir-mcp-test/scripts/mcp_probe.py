#!/usr/bin/env python3
"""Small MCP client for testing a running MCP server. Standard library only.

Transports: Streamable HTTP (--url) or stdio (--stdio "command").
Protocol modes:
  modern      2026-07-28, stateless, Tasks extension (io.modelcontextprotocol/tasks)
  tasks-2025  2025-11-25 with session and the "tasks" capability
  plain       2025-11-25 without tasks (the tool call waits for the result)
  auto        try modern, then tasks-2025, then plain

Output: the final JSON goes to stdout. Progress lines go to stderr.
Exit codes: 0 ok, 1 MCP error / failed or cancelled task / failed check, 2 usage or connection error.
"""

import argparse
import json
import os
import shlex
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

MODERN = "2026-07-28"
LEGACY = "2025-11-25"
TASKS_EXT = "io.modelcontextprotocol/tasks"
TERMINAL = {"completed", "failed", "cancelled"}
# FastestMCP also needs Mcp-Name on tasks/*. ExMCP ignores it there.
NAME_SOURCES = {"tools/call": "name", "resources/read": "uri", "prompts/get": "name",
                "tasks/get": "taskId", "tasks/update": "taskId", "tasks/cancel": "taskId"}
SESSION_FILE = os.path.join(tempfile.gettempdir(), "mcp_probe_sessions.json")


def log(msg):
    print(msg, file=sys.stderr, flush=True)


class ProbeError(Exception):
    pass


class RpcError(Exception):
    def __init__(self, error):
        super().__init__(json.dumps(error))
        self.error = error


# ---------------------------------------------------------------- transports


class HttpTransport:
    def __init__(self, url, timeout, headers):
        self.url = url
        self.timeout = timeout
        self.extra_headers = headers
        self.session_id = None

    def send(self, message, headers=None, expect_reply=True):
        body = json.dumps(message).encode()
        req = urllib.request.Request(self.url, data=body, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json, text/event-stream")
        for k, v in {**self.extra_headers, **(headers or {})}.items():
            req.add_header(k, v)
        if self.session_id:
            req.add_header("Mcp-Session-Id", self.session_id)
        try:
            resp = urllib.request.urlopen(req, timeout=self.timeout)
        except urllib.error.HTTPError as e:
            text = e.read().decode(errors="replace")
            try:
                data = json.loads(text)
                if "error" in data:
                    raise RpcError(data["error"])
            except json.JSONDecodeError:
                pass
            raise ProbeError(f"HTTP {e.code}: {text[:500]}")
        except (urllib.error.URLError, OSError) as e:
            raise ProbeError(f"cannot reach {self.url}: {e}")

        sid = resp.headers.get("Mcp-Session-Id")
        if sid:
            self.session_id = sid
        if not expect_reply:
            resp.read()
            return None
        ctype = resp.headers.get("Content-Type", "")
        raw = resp.read().decode(errors="replace")
        if "text/event-stream" in ctype:
            return self._from_sse(raw, message.get("id"))
        if not raw.strip():
            raise ProbeError("empty response body")
        return json.loads(raw)

    def _from_sse(self, raw, want_id):
        reply = None
        for event in raw.replace("\r\n", "\n").split("\n\n"):
            data = "\n".join(
                line[5:].lstrip() for line in event.split("\n") if line.startswith("data:")
            )
            if not data.strip():
                continue
            msg = json.loads(data)
            if msg.get("id") == want_id and ("result" in msg or "error" in msg):
                reply = msg
            elif "method" in msg:
                show_notification(msg)
        if reply is None:
            raise ProbeError("no reply in the event stream")
        return reply

    def close(self):
        pass


class StdioTransport:
    def __init__(self, command, timeout):
        self.timeout = timeout
        self.session_id = None
        self.proc = subprocess.Popen(
            command,
            shell=True,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=sys.stderr,
            text=True,
            bufsize=1,
        )

    def send(self, message, headers=None, expect_reply=True):
        try:
            self.proc.stdin.write(json.dumps(message) + "\n")
            self.proc.stdin.flush()
        except OSError:
            raise ProbeError(f"server process exited (code {self.proc.poll()})")
        if not expect_reply:
            return None
        deadline = time.time() + self.timeout
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                raise ProbeError("server closed stdout")
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                # Logger or IO.puts on stdout breaks stdio MCP clients.
                log(f"WARNING: non-JSON line on stdout: {line[:200]}")
                continue
            if msg.get("id") == message.get("id") and ("result" in msg or "error" in msg):
                return msg
            if "method" in msg:
                show_notification(msg)
        raise ProbeError("timeout waiting for a reply")

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def show_notification(msg):
    params = msg.get("params", {})
    method = msg.get("method")
    if method == "notifications/progress":
        log(f"  progress {params.get('progress')}/{params.get('total')} {params.get('message', '')}")
    elif method == "notifications/tasks":
        log(f"  task {params.get('taskId')}: {params.get('status')} {params.get('statusMessage', '')}")
    else:
        log(f"  notification {method}: {json.dumps(params)[:200]}")


# ---------------------------------------------------------------- client


class Client:
    def __init__(self, transport, mode, is_http):
        self.t = transport
        self.mode = mode
        self.is_http = is_http
        self.next_id = 1
        self.server_info = None
        self.capabilities = None
        self.protocol = None

    def _id(self):
        self.next_id += 1
        return self.next_id

    def request(self, method, params=None):
        params = dict(params or {})
        headers = {}
        if self.mode == "modern":
            params["_meta"] = {
                "io.modelcontextprotocol/protocolVersion": MODERN,
                "io.modelcontextprotocol/clientCapabilities": {"extensions": {TASKS_EXT: {}}},
                "io.modelcontextprotocol/clientInfo": {"name": "mcp_probe", "version": "1"},
                **params.get("_meta", {}),
            }
            headers = {"MCP-Protocol-Version": MODERN, "Mcp-Method": method}
            field = NAME_SOURCES.get(method)
            if field and isinstance(params.get(field), str):
                headers["Mcp-Name"] = params[field]
        elif self.protocol:
            headers = {"MCP-Protocol-Version": self.protocol}
        msg = {"jsonrpc": "2.0", "id": self._id(), "method": method, "params": params}
        reply = self.t.send(msg, headers)
        if "error" in reply:
            raise RpcError(reply["error"])
        return reply["result"]

    def initialize(self, with_tasks):
        caps = {"tasks": {}} if with_tasks else {}
        msg = {
            "jsonrpc": "2.0",
            "id": self._id(),
            "method": "initialize",
            "params": {
                "protocolVersion": LEGACY,
                "capabilities": caps,
                "clientInfo": {"name": "mcp_probe", "version": "1"},
            },
        }
        reply = self.t.send(msg)
        if "error" in reply:
            raise RpcError(reply["error"])
        result = reply["result"]
        self.protocol = result.get("protocolVersion", LEGACY)
        self.server_info = result.get("serverInfo")
        self.capabilities = result.get("capabilities", {})
        self.t.send({"jsonrpc": "2.0", "method": "notifications/initialized"},
                    {"MCP-Protocol-Version": self.protocol}, expect_reply=False)
        return result

    # --- tasks, normalized over both task versions

    def call_tool(self, name, arguments, as_task):
        params = {"name": name, "arguments": arguments}
        # ExMCP (modern) starts a task from the capability alone; FastestMCP needs "task".
        if as_task and self.mode != "plain":
            params["task"] = {"ttl": 600_000}
        return self.request("tools/call", params)

    @staticmethod
    def task_of(result):
        """Returns the task map of a tools/call or tasks/get result, or None."""
        if result.get("resultType") == "task" or ("taskId" in result and "status" in result):
            return result
        if isinstance(result.get("task"), dict):
            return result["task"]
        return None

    def get_task(self, task_id):
        return self.request("tasks/get", {"taskId": task_id})

    def task_result(self, task_id):
        return self.request("tasks/result", {"taskId": task_id})

    def cancel_task(self, task_id):
        return self.request("tasks/cancel", {"taskId": task_id})

    def wait(self, task_id, timeout, cancel_after=None, interval=None):
        start = time.time()
        cancelled = False
        last = None
        while True:
            task = self.get_task(task_id)
            status = task.get("status")
            line = f"{status} {task.get('statusMessage', '')}".strip()
            if line != last:
                log(f"  [{time.time() - start:5.1f}s] {line}")
                last = line
            if status in TERMINAL:
                return task, time.time() - start
            if cancel_after is not None and not cancelled and time.time() - start >= cancel_after:
                log(f"  [{time.time() - start:5.1f}s] sending tasks/cancel")
                self.cancel_task(task_id)
                cancelled = True
            if time.time() - start > timeout:
                raise ProbeError(f"task {task_id} still {status} after {timeout}s")
            server_ms = task.get("pollIntervalMs") or task.get("pollInterval") or 1000
            time.sleep(interval if interval else min(server_ms / 1000, 1.0))

    def final_payload(self, task):
        """The tool result or error of a finished task."""
        if self.mode == "modern":
            return {k: task[k] for k in ("result", "error") if k in task}
        if task["status"] in ("completed", "failed"):
            try:
                return {"result": self.task_result(task["taskId"])}
            except RpcError as e:
                return {"error": e.error}
        return {}


# ---------------------------------------------------------------- session reuse (HTTP legacy modes)


def load_sessions():
    try:
        with open(SESSION_FILE) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def save_session(url, client):
    data = load_sessions()
    data[url] = {"session_id": client.t.session_id, "mode": client.mode, "protocol": client.protocol}
    with open(SESSION_FILE, "w") as f:
        json.dump(data, f)


def connect(args):
    if args.stdio:
        transport = StdioTransport(args.stdio, args.timeout)
        is_http = False
    elif args.url:
        headers = dict(h.split(":", 1) for h in args.header)
        headers = {k.strip(): v.strip() for k, v in headers.items()}
        transport = HttpTransport(args.url, args.timeout, headers)
        is_http = True
    else:
        raise ProbeError("give --url or --stdio")

    # A task id belongs to the mode (and session) that created it, so task commands reuse them.
    if is_http and not args.new_session and args.command in ("get", "result", "cancel", "wait"):
        saved = load_sessions().get(args.url)
        if saved and args.mode in ("auto", saved["mode"]):
            transport.session_id = saved.get("session_id")
            c = Client(transport, saved["mode"], is_http)
            c.protocol = saved.get("protocol")
            return c

    modes = [args.mode] if args.mode != "auto" else (
        ["modern", "tasks-2025", "plain"] if is_http else ["tasks-2025", "plain"])
    fallback = None
    last_error = None
    for mode in modes:
        c = Client(transport, mode, is_http)
        try:
            if mode == "modern":
                c.request("tools/list")
                c.protocol = MODERN
                has_tasks = modern_has_tasks(c)
            else:
                result = c.initialize(with_tasks=(mode == "tasks-2025"))
                has_tasks = "tasks" in result.get("capabilities", {})
                if mode == "tasks-2025" and not has_tasks:
                    c.mode = "plain"
            if args.mode == "auto" and mode != "plain" and not has_tasks:
                log(f"mode {mode} works, but the server has no tasks there")
                fallback = fallback or c
                transport.session_id = None
                continue
            return connected(args, c, is_http)
        except (RpcError, ProbeError) as e:
            last_error = e
            log(f"mode {mode} did not work: {e}")
            transport.session_id = None
    if fallback:
        if fallback.mode != "modern":
            fallback.initialize(with_tasks=False)
        return connected(args, fallback, is_http)
    raise ProbeError(f"could not connect: {last_error}")


def modern_has_tasks(c):
    try:
        c.get_task("__probe__")
    except RpcError as e:
        return e.error.get("code") != -32601
    return True


def connected(args, c, is_http):
    log(f"connected: mode={c.mode} protocol={c.protocol}")
    if is_http:
        save_session(args.url, c)
    return c


# ---------------------------------------------------------------- commands


def out(value):
    print(json.dumps(value, indent=2, ensure_ascii=False))


def cmd_info(c, args):
    if c.mode == "modern":
        out({"mode": c.mode, "protocol": MODERN, "discover": safe(lambda: c.request("server/discover"))})
    else:
        out({"mode": c.mode, "protocol": c.protocol, "serverInfo": c.server_info, "capabilities": c.capabilities})
    return 0


def safe(fn):
    try:
        return fn()
    except (RpcError, ProbeError) as e:
        return {"unavailable": str(e)}


def cmd_list(c, args):
    out(c.request("tools/list"))
    return 0


def cmd_call(c, args):
    arguments = json.loads(args.args)
    as_task = c.mode != "plain" and not args.no_task
    started = time.time()
    result = c.call_tool(args.name, arguments, as_task)
    task = Client.task_of(result)
    if task is None:
        out({"kind": "direct", "seconds": round(time.time() - started, 2), "result": result})
        return 1 if result.get("isError") else 0
    log(f"task {task['taskId']}: {task.get('status')}")
    if not args.wait:
        out({"kind": "task", "task": task})
        return 0
    final, seconds = c.wait(task["taskId"], args.wait_timeout, args.cancel_after, args.interval)
    payload = c.final_payload(final)
    out({"kind": "task", "taskId": final["taskId"], "status": final["status"],
         "seconds": round(seconds, 2), **payload})
    is_error = final["status"] != "completed" or payload.get("result", {}).get("isError")
    return 1 if is_error else 0


def cmd_get(c, args):
    out(c.get_task(args.task_id))
    return 0


def cmd_wait(c, args):
    final, seconds = c.wait(args.task_id, args.wait_timeout, args.cancel_after, args.interval)
    out({"taskId": final["taskId"], "status": final["status"], "seconds": round(seconds, 2),
         **c.final_payload(final)})
    return 0 if final["status"] == "completed" else 1


def cmd_result(c, args):
    out(c.task_result(args.task_id))
    return 0


def cmd_cancel(c, args):
    out(c.cancel_task(args.task_id))
    return 0


def cmd_raw(c, args):
    out(c.request(args.method, json.loads(args.params)))
    return 0


def cmd_smoke(c, args):
    """Generic checks that every MCP server must pass."""
    checks = []

    def check(name, fn):
        try:
            detail = fn()
            checks.append({"check": name, "passed": True, "detail": detail})
        except Exception as e:  # noqa: BLE001 - report every failure as a check result
            checks.append({"check": name, "passed": False, "detail": str(e)})

    tools = []

    def list_tools():
        tools.extend(c.request("tools/list").get("tools", []))
        assert tools, "no tools"
        return [t["name"] for t in tools]

    def tool_shapes():
        problems = []
        for t in tools:
            if not t.get("description"):
                problems.append(f"{t['name']}: no description")
            if (t.get("inputSchema") or {}).get("type") != "object":
                problems.append(f"{t['name']}: inputSchema.type is not 'object'")
        assert not problems, "; ".join(problems)
        return "all tools have a description and an object input schema"

    def unknown_tool():
        try:
            r = c.call_tool("__no_such_tool__", {}, as_task=False)
        except RpcError as e:
            return f"JSON-RPC error {e.error.get('code')}"
        assert r.get("isError"), f"no error for an unknown tool: {r}"
        return "isError result"

    def unknown_task():
        try:
            r = c.get_task("__no_such_task__")
        except RpcError as e:
            return f"JSON-RPC error {e.error.get('code')}: {e.error.get('message')}"
        raise AssertionError(f"no error for an unknown task: {r}")

    check("tools/list returns tools", list_tools)
    if tools:
        check("tool descriptions and input schemas", tool_shapes)
    check("unknown tool gives an error", unknown_tool)
    if c.mode != "plain":
        check("unknown task id gives an error", unknown_task)

    if args.tool:
        def good_call():
            arguments = json.loads(args.args)
            r = c.call_tool(args.tool, arguments, c.mode != "plain")
            task = Client.task_of(r)
            if task is None:
                assert not r.get("isError"), f"tool error: {r}"
                return "direct result"
            final, seconds = c.wait(task["taskId"], args.wait_timeout)
            assert final["status"] == "completed", f"status {final['status']}: {c.final_payload(final)}"
            return f"completed in {seconds:.1f}s"
        check(f"{args.tool} with valid args completes", good_call)

    if args.tool and args.bad_args:
        def bad_call():
            try:
                r = c.call_tool(args.tool, json.loads(args.bad_args), c.mode != "plain")
            except RpcError as e:
                return f"JSON-RPC error {e.error.get('code')}"
            task = Client.task_of(r)
            if task is None:
                assert r.get("isError"), f"invalid args were accepted: {r}"
                return "isError result, no task"
            # FastestMCP validates inside the task, so the task fails at once.
            final, seconds = c.wait(task["taskId"], args.wait_timeout)
            assert final["status"] == "failed", f"task with invalid args ended {final['status']}"
            return f"task failed after {seconds:.1f}s (check that no job started)"
        check(f"{args.tool} with invalid args is rejected", bad_call)

    out({"mode": c.mode, "checks": checks})
    return 0 if all(ch["passed"] for ch in checks) else 1


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", help="Streamable HTTP endpoint, for example http://localhost:4000/mcp")
    p.add_argument("--stdio", help='command that starts a stdio server, for example "mix run --no-halt stdio.exs"')
    p.add_argument("--mode", default="auto", choices=["auto", "modern", "tasks-2025", "plain"])
    p.add_argument("--header", action="append", default=[], help='extra HTTP header, "Name: value"')
    p.add_argument("--timeout", type=float, default=60, help="seconds for one request")
    p.add_argument("--new-session", action="store_true", help="do not reuse a saved HTTP session")
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("info")
    sub.add_parser("list")

    def wait_opts(sp):
        sp.add_argument("--wait-timeout", type=float, default=120)
        sp.add_argument("--cancel-after", type=float, help="send tasks/cancel after this many seconds")
        sp.add_argument("--interval", type=float, help="poll interval in seconds")

    sp = sub.add_parser("call")
    sp.add_argument("name")
    sp.add_argument("--args", default="{}", help="tool arguments as JSON")
    sp.add_argument("--wait", action="store_true", help="poll the task until it finishes")
    sp.add_argument("--no-task", action="store_true", help="do not ask for a task")
    wait_opts(sp)

    for name in ("get", "result", "cancel"):
        sub.add_parser(name).add_argument("task_id")
    sp = sub.add_parser("wait")
    sp.add_argument("task_id")
    wait_opts(sp)

    sp = sub.add_parser("raw")
    sp.add_argument("method")
    sp.add_argument("--params", default="{}")

    sp = sub.add_parser("smoke")
    sp.add_argument("--tool", help="a tool to call with --args")
    sp.add_argument("--args", default="{}")
    sp.add_argument("--bad-args", help="arguments that the input schema must reject")
    sp.add_argument("--wait-timeout", type=float, default=120)

    args = p.parse_args()
    commands = {"info": cmd_info, "list": cmd_list, "call": cmd_call, "get": cmd_get, "wait": cmd_wait,
                "result": cmd_result, "cancel": cmd_cancel, "raw": cmd_raw, "smoke": cmd_smoke}
    client = None
    try:
        client = connect(args)
        sys.exit(commands[args.command](client, args))
    except RpcError as e:
        out({"error": e.error})
        sys.exit(1)
    except ProbeError as e:
        log(f"ERROR: {e}")
        sys.exit(2)
    finally:
        if client:
            client.t.close()


if __name__ == "__main__":
    main()
