import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

from lightpanda import ToolError, run_script


def test_goto_and_markdown(browser, fixture_url):
    page = browser.new_session()
    page.goto(url=f"{fixture_url}/index.html")
    text = page.markdown()
    assert "Hello from the fixture" in text
    page.close()


def test_extract_dict_schema(browser, fixture_url):
    with browser.new_session() as page:
        page.goto(url=f"{fixture_url}/index.html")
        data = page.extract(schema={"headline": "#headline", "items": [".item a"]})
        assert data["headline"] == "Hello from the fixture"
        assert data["items"] == ["First item", "Second item", "Third item"]


def test_evaluate(browser, fixture_url):
    with browser.new_session() as page:
        page.goto(url=f"{fixture_url}/index.html")
        assert page.evaluate(script="1 + 2") == 3
        assert page.evaluate(script="document.title") == "Fixture Home"


def test_snake_case_alias(browser, fixture_url):
    with browser.new_session() as page:
        page.goto(url=f"{fixture_url}/index.html")
        assert page.get_url() == page.getUrl()


def test_sessions_are_isolated(browser, fixture_url):
    with browser.new_session() as a, browser.new_session() as b:
        a.goto(url=f"{fixture_url}/index.html")
        b.goto(url=f"{fixture_url}/other.html")
        assert a.get_url().endswith("/index.html")
        assert b.get_url().endswith("/other.html")


def test_tool_error_raises(browser, fixture_url):
    with browser.new_session() as page:
        page.goto(url=f"{fixture_url}/index.html")
        with pytest.raises(ToolError):
            page.extract(schema={"nope": "#does-not-exist"})


def test_unknown_tool_raises(browser):
    with browser.new_session() as page:
        with pytest.raises(ToolError, match="unknown tool"):
            page.call("teleport", where="moon")


def test_extra_args_passthrough(binary, fixture_url, tmp_path):
    from lightpanda import Browser

    cache_dir = tmp_path / "cache"
    with Browser(binary=binary, args=["--http-cache-dir", str(cache_dir)]) as b:
        with b.new_session() as page:
            page.goto(url=f"{fixture_url}/index.html")
            assert "Hello" in page.markdown()
    assert cache_dir.exists()


@pytest.mark.skipif(sys.platform != "linux", reason="PDEATHSIG is Linux-only")
def test_sidecar_dies_with_killed_parent(binary, tmp_path):
    child_src = tmp_path / "spawn_and_hang.py"
    child_src.write_text(
        "import os, sys, time\n"
        "from lightpanda import Browser\n"
        "b = Browser(binary=sys.argv[1])\n"
        "print(b._client._proc.pid, flush=True)\n"
        "time.sleep(60)\n"
    )
    env = dict(os.environ, PYTHONPATH=str(Path(__file__).parent.parent))
    child = subprocess.Popen(
        [sys.executable, str(child_src), binary],
        stdout=subprocess.PIPE, text=True, env=env,
    )
    sidecar_pid = int(child.stdout.readline())
    assert _alive(sidecar_pid)

    os.kill(child.pid, signal.SIGKILL)
    child.wait()
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and _alive(sidecar_pid):
        time.sleep(0.1)
    assert not _alive(sidecar_pid), "sidecar survived its parent's SIGKILL"


def _alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def test_run_script(binary, fixture_url, tmp_path):
    script = tmp_path / "visit.js"
    script.write_text('const page = new Page();\nawait page.goto("$LP_TEST_URL");\n')
    run_script(script, env={"LP_TEST_URL": f"{fixture_url}/index.html"}, binary=binary)
