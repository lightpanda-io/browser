class LightpandaError(Exception):
    """Base error for the lightpanda package."""


class ProtocolError(LightpandaError):
    """JSON-RPC level failure (invalid request, timeout, internal error)."""

    def __init__(self, message: str, code: int | None = None):
        super().__init__(message)
        self.code = code


class ToolError(LightpandaError):
    """A browser tool reported failure (bad selector, JS exception, ...)."""


class ScriptError(LightpandaError):
    """A script replay (`run_script`) exited with a failure."""

    def __init__(self, message: str, returncode: int, stdout: str = "", stderr: str = ""):
        super().__init__(message)
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
