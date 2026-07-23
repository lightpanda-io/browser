"""Lightpanda for Python: a lightweight headless browser.

```python
from lightpanda import Browser

with Browser() as b:
    page = b.new_session()
    page.goto(url="https://example.com")
    data = page.extract(schema={"title": "h1"})
```
"""

from .browser import Browser, Session, run_script
from .errors import LightpandaError, ProtocolError, ScriptError, ToolError

__all__ = [
    "Browser",
    "Session",
    "run_script",
    "LightpandaError",
    "ProtocolError",
    "ScriptError",
    "ToolError",
]
