"""Subprocess management and MCP-over-HTTP JSON-RPC transport.

The bundled ``lightpanda`` binary is spawned in ``mcp --port <n>`` mode
(MCP Streamable HTTP on 127.0.0.1). Each JSON-RPC message is one POST;
session routing uses the ``Mcp-Session-Id`` header — an unknown id creates
the session on first use, so the client mints its own ids. DELETE with the
header tears a session down.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

from .errors import LightpandaError, ProtocolError

BINARY_NAME = "lightpanda.exe" if sys.platform == "win32" else "lightpanda"

_SPAWN_ATTEMPTS = 3
_READY_TIMEOUT = 15.0


def find_binary(explicit: str | os.PathLike | None = None) -> Path:
    """Locate the lightpanda binary: explicit arg, $LIGHTPANDA_BIN, the
    bundled package copy, then PATH."""
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit))
    env = os.environ.get("LIGHTPANDA_BIN")
    if env:
        candidates.append(Path(env))
    candidates.append(Path(__file__).parent / BINARY_NAME)
    which = shutil.which("lightpanda")
    if which:
        candidates.append(Path(which))

    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise LightpandaError(
        "could not find the lightpanda binary; reinstall the package, set "
        "LIGHTPANDA_BIN, or put `lightpanda` on PATH"
    )


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Client:
    """Owns one lightpanda subprocess and speaks JSON-RPC to it."""

    def __init__(
        self,
        binary: str | os.PathLike | None = None,
        env: dict[str, str] | None = None,
        timeout: float = 300.0,
        verbose: bool = False,
        args: tuple[str, ...] | list[str] = (),
    ):
        self._binary = find_binary(binary)
        self._extra_args = list(args)
        self._timeout = timeout
        self._lock = threading.Lock()
        self._id = 0
        self._proc: subprocess.Popen | None = None
        self._port = 0

        child_env = dict(os.environ)
        if env:
            child_env.update(env)

        stderr = None if verbose else subprocess.DEVNULL
        last_error: Exception | None = None
        for _ in range(_SPAWN_ATTEMPTS):
            port = _free_port()
            proc = subprocess.Popen(
                [str(self._binary), "mcp", "--port", str(port), *self._extra_args],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=stderr,
                env=child_env,
            )
            try:
                self._wait_ready(proc, port)
            except LightpandaError as err:
                last_error = err
                self._terminate(proc)
                continue
            self._proc = proc
            self._port = port
            return
        raise LightpandaError(f"failed to start lightpanda: {last_error}")

    @staticmethod
    def _wait_ready(proc: subprocess.Popen, port: int) -> None:
        deadline = time.monotonic() + _READY_TIMEOUT
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise LightpandaError(
                    f"lightpanda exited during startup (code {proc.returncode})"
                )
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.25):
                    return
            except OSError:
                time.sleep(0.05)
        raise LightpandaError("timed out waiting for lightpanda to listen")

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self._port}/"

    def _http(self, method: str, body: bytes | None, session_id: str | None) -> tuple[int, bytes]:
        headers = {"Content-Type": "application/json"}
        if session_id:
            headers["Mcp-Session-Id"] = session_id
        req = urllib.request.Request(self.base_url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=self._timeout) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as err:
            return err.code, err.read()
        except OSError as err:
            alive = self._proc is not None and self._proc.poll() is None
            state = "running" if alive else f"exited (code {self._proc.returncode})" if self._proc else "not started"
            raise LightpandaError(f"lost connection to lightpanda ({state}): {err}") from err

    def request(self, method: str, params: dict | None = None, session_id: str | None = None):
        """Send one JSON-RPC request and return its ``result``."""
        with self._lock:
            self._id += 1
            rpc_id = self._id
        message: dict = {"jsonrpc": "2.0", "id": rpc_id, "method": method}
        if params is not None:
            message["params"] = params

        status, body = self._http("POST", json.dumps(message).encode(), session_id)
        if not body:
            raise ProtocolError(f"empty response (HTTP {status}) for {method}")
        try:
            payload = json.loads(body)
        except ValueError as err:
            raise ProtocolError(f"invalid JSON-RPC response for {method}: {body[:200]!r}") from err
        if error := payload.get("error"):
            raise ProtocolError(f"{error.get('message', 'error')} (code {error.get('code')})", code=error.get("code"))
        return payload.get("result")

    def notify(self, method: str, session_id: str | None = None) -> None:
        message = {"jsonrpc": "2.0", "method": method}
        self._http("POST", json.dumps(message).encode(), session_id)

    def delete_session(self, session_id: str) -> None:
        self._http("DELETE", None, session_id)

    @staticmethod
    def _terminate(proc: subprocess.Popen) -> None:
        if proc.poll() is not None:
            return
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()

    def close(self) -> None:
        if self._proc is not None:
            self._terminate(self._proc)
            self._proc = None

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass
