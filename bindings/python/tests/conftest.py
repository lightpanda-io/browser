import http.server
import os
import threading
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent.parent.parent
FIXTURES = Path(__file__).parent / "fixtures"


def _binary() -> str | None:
    env = os.environ.get("LIGHTPANDA_BIN")
    if env and Path(env).is_file():
        return env
    built = REPO_ROOT / "zig-out" / "bin" / "lightpanda"
    if built.is_file():
        return str(built)
    return None


@pytest.fixture(scope="session")
def binary() -> str:
    path = _binary()
    if path is None:
        pytest.skip("no lightpanda binary (set LIGHTPANDA_BIN or build zig-out/bin/lightpanda)")
    return path


@pytest.fixture(scope="session")
def fixture_url():
    handler = lambda *args: http.server.SimpleHTTPRequestHandler(*args, directory=str(FIXTURES))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_address[1]}"
    server.shutdown()


@pytest.fixture(scope="session")
def browser(binary):
    from lightpanda import Browser

    with Browser(binary=binary) as b:
        yield b
