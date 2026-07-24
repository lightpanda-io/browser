# lightpanda for Python

Scrape and automate the web from Python with the [Lightpanda](https://lightpanda.io)
headless browser — an order of magnitude lighter than Chrome. The wheel bundles
the browser binary; there is no separate install step.

```python
from lightpanda import Browser

with Browser() as b:
    page = b.new_session()
    page.goto(url="https://example.com")
    data = page.extract(schema={"title": "h1"})
```

Every browser tool is a `Session` method (both `waitForSelector` and
`wait_for_selector` work), with kwargs matching the tool's documented
arguments. Replay a saved lightpanda agent script without any LLM:

```python
from lightpanda import run_script

run_script("hn.lp.js", env={"LP_HN_USERNAME": "me"})
```

The package also puts the full `lightpanda` CLI on PATH (agent REPL, fetch,
serve).

## Development

The runtime binary is resolved from `LIGHTPANDA_BIN`, the package directory,
then PATH. For a repo checkout: build with `zig build` and run tests with

```bash
uv run --group dev pytest tests
```

Regenerate the tool methods (`lightpanda/_methods.py`) and the API docs:

```bash
uv run --no-project python scripts/generate_methods.py
uv run --no-project --with pdoc python scripts/build_docs.py   # writes docs/
```
