"""Build an installable legacy Blender add-on zip without external tools."""

from __future__ import annotations

import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent
PACKAGE = ROOT / "neura_asset_exporter"
OUTPUT = ROOT / "neura_asset_exporter.zip"


def main() -> None:
    with zipfile.ZipFile(OUTPUT, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(PACKAGE.rglob("*")):
            if path.is_dir() or "__pycache__" in path.parts or path.suffix == ".pyc":
                continue
            archive.write(path, path.relative_to(PACKAGE))
    print(f"Built {OUTPUT}")


if __name__ == "__main__":
    main()
