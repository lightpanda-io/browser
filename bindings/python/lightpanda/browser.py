"""Public API: Browser, Session, run_script.

Session tool methods are generated from the server's ``tools/list`` schemas —
one method per browser tool, kwargs exactly the tool's schema properties.
Both the original tool name (``waitForSelector``) and its snake_case form
(``wait_for_selector``) resolve to the same method.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path

from .client import Client, find_binary
from .errors import ProtocolError, ScriptError, ToolError

try:
    from ._methods import SessionMethods
except ImportError:
    # Bootstrap: scripts/generate_methods.py itself imports this module
    # before _methods.py exists; tool calls then rely on __getattr__.
    class SessionMethods:
        pass


_SESSION_TOOLS = {"save", "session_new", "session_list", "session_close"}


def _snake(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def _parse_result_text(text: str):
    """Tool results are text; JSON payloads (extract, links, tree, ...) are
    returned parsed, anything else as the raw string."""
    try:
        return json.loads(text)
    except ValueError:
        return text


class Session(SessionMethods):
    """One isolated browsing context (own page, cookies, memory).

    Do not construct directly — use :meth:`Browser.new_session`.
    """

    def __init__(self, client: Client, session_id: str, tools: dict[str, dict]):
        self._client = client
        self._id = session_id
        self._tools = tools
        self._snake_map = {_snake(name): name for name in tools}
        self._closed = False

        self._client.request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "lightpanda-python", "version": _version()},
            },
            session_id=self._id,
        )
        self._client.notify("notifications/initialized", session_id=self._id)

    @property
    def id(self) -> str:
        return self._id

    def call(self, tool: str, **kwargs):
        """Invoke a browser tool by name. The generated methods route here."""
        if self._closed:
            raise ToolError(f"session {self._id} is closed")
        name = self._snake_map.get(tool, tool)
        if name not in self._tools:
            raise ToolError(f"unknown tool {tool!r}")
        kwargs = {k: v for k, v in kwargs.items() if v is not None}
        if name == "extract" and isinstance(kwargs.get("schema"), (dict, list)):
            kwargs["schema"] = json.dumps(kwargs["schema"])

        result = self._client.request(
            "tools/call", {"name": name, "arguments": kwargs}, session_id=self._id
        )
        content = result.get("content") or []
        text = "\n".join(part.get("text", "") for part in content if part.get("type") == "text")
        if result.get("isError"):
            raise ToolError(text or f"{name} failed")
        return _parse_result_text(text)

    def __getattr__(self, attr: str):
        tools = self.__dict__.get("_tools") or {}
        name = self.__dict__.get("_snake_map", {}).get(attr, attr)
        if name in tools and name not in _SESSION_TOOLS:
            def method(**kwargs):
                return self.call(name, **kwargs)

            method.__name__ = attr
            method.__qualname__ = f"Session.{attr}"
            method.__doc__ = tools[name].get("description")
            return method
        raise AttributeError(f"{type(self).__name__!r} object has no attribute {attr!r}")

    def __dir__(self):
        names = set(super().__dir__())
        for name in self._tools:
            if name not in _SESSION_TOOLS:
                names.add(name)
                names.add(_snake(name))
        return sorted(names)

    def close(self) -> None:
        if not self._closed:
            self._closed = True
            self._client.delete_session(self._id)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


# pdoc hides members inherited from a private module; re-attach the generated
# tool methods as Session's own so they document (and introspect) directly.
for _name, _member in vars(SessionMethods).items():
    if not _name.startswith("_") and _name != "call":
        setattr(Session, _name, _member)


# pdoc hides members inherited from a private module; re-attach the generated
# tool methods as Session's own so they document (and introspect) directly.
for _name, _member in vars(SessionMethods).items():
    if not _name.startswith("_") and _name != "call":
        setattr(Session, _name, _member)


class Browser:
    """A lightpanda browser process. Spawns the bundled binary on first use.

    Not fork-inheritable: after ``os.fork()``/``multiprocessing``, create a
    fresh Browser in the child.
    """

    def __init__(
        self,
        binary: str | os.PathLike | None = None,
        env: dict[str, str] | None = None,
        timeout: float = 300.0,
        verbose: bool = False,
        args: tuple[str, ...] | list[str] = (),
    ):
        """``args`` are extra CLI flags for the spawned browser process
        (e.g. ``["--http-cache-dir", path]`` or cookie flags)."""
        self._client = Client(binary=binary, env=env, timeout=timeout, verbose=verbose, args=args)
        self._seq = 0
        listed = self._client.request("tools/list")
        self._tools = {
            tool["name"]: {
                "description": tool.get("description", ""),
                "schema": tool.get("inputSchema") or {},
            }
            for tool in listed.get("tools", [])
        }

    @property
    def tools(self) -> dict[str, dict]:
        """Tool name → {description, schema}, as reported by the browser."""
        return self._tools

    def new_session(self) -> Session:
        self._seq += 1
        return Session(self._client, f"py{self._seq}", self._tools)

    def close(self) -> None:
        self._client.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def run_script(
    script: str | os.PathLike,
    env: dict[str, str] | None = None,
    binary: str | os.PathLike | None = None,
    timeout: float | None = None,
) -> str:
    """Replay a saved lightpanda script (no LLM) and return its stdout.

    ``env`` entries (e.g. ``LP_*`` placeholder values) are added to the
    child's environment. Raises :class:`ScriptError` on a non-zero exit.
    """
    path = Path(script)
    if not path.is_file():
        raise ScriptError(f"script not found: {path}", returncode=-1)
    child_env = dict(os.environ)
    if env:
        child_env.update(env)

    proc = subprocess.run(
        [str(find_binary(binary)), "run", str(path)],
        env=child_env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip() or "no output"
        raise ScriptError(
            f"{path.name} failed (exit {proc.returncode}): {detail}",
            returncode=proc.returncode,
            stdout=proc.stdout,
            stderr=proc.stderr,
        )
    return proc.stdout


def _version() -> str:
    try:
        from importlib.metadata import version

        return version("lightpanda")
    except Exception:
        return "0.0.0.dev0"


__all__ = ["Browser", "Session", "run_script", "ProtocolError", "ScriptError", "ToolError"]
