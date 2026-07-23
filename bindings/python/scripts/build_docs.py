"""Generate API documentation with pdoc (zignal's flow, adapted).

Usage, from bindings/python (needs a lightpanda binary for regeneration):
    uv run --group docs python scripts/build_docs.py
"""

import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent.parent


def main():
    print("Regenerating tool methods from the binary...")
    if subprocess.call([sys.executable, str(HERE / "scripts" / "generate_methods.py")]) != 0:
        sys.exit("error: failed to regenerate lightpanda/_methods.py")

    docs_dir = HERE / "docs"
    if docs_dir.exists():
        shutil.rmtree(docs_dir)

    print("Generating documentation...")
    cmd = [sys.executable, "-m", "pdoc", "lightpanda", "-o", str(docs_dir), "--no-show-source"]
    if subprocess.call(cmd, cwd=HERE) != 0:
        sys.exit("error generating documentation")
    print(f"documentation generated in {docs_dir}")


if __name__ == "__main__":
    main()
