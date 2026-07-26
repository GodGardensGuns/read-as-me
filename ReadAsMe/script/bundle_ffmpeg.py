#!/usr/bin/env python3
"""Copy ffmpeg/ffprobe and their non-system dylibs into a relocatable app runtime."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path


def output(*command: str) -> str:
    return subprocess.check_output(command, text=True)


def dependencies(binary: Path) -> list[tuple[str, Path]]:
    result: list[tuple[str, Path]] = []
    for line in output("otool", "-L", str(binary)).splitlines()[1:]:
        value = line.strip().split(" (", 1)[0]
        if value.startswith(("/System/", "/usr/lib/", "@")):
            continue
        path = Path(value)
        if path.exists():
            result.append((value, path.resolve()))
    return result


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: bundle_ffmpeg.py <source-bin-folder> <runtime-folder>")
    source_bin = Path(sys.argv[1])
    runtime = Path(sys.argv[2])
    bin_dir = runtime / "bin"
    lib_dir = runtime / "lib"
    bin_dir.mkdir(parents=True, exist_ok=True)
    lib_dir.mkdir(parents=True, exist_ok=True)

    roots = [source_bin / "ffmpeg", source_bin / "ffprobe"]
    for root in roots:
        if not root.exists():
            raise SystemExit(f"missing required executable: {root}")
        shutil.copy2(root.resolve(), bin_dir / root.name)

    queue = [path for root in roots for _, path in dependencies(root.resolve())]
    copied: dict[Path, Path] = {}
    while queue:
        source = queue.pop(0)
        if source in copied:
            continue
        destination = lib_dir / source.name
        if destination.exists() and destination.stat().st_size != source.stat().st_size:
            raise SystemExit(f"conflicting dylib basename: {source.name}")
        shutil.copy2(source, destination)
        copied[source] = destination
        queue.extend(path for _, path in dependencies(source))

    all_targets = list((bin_dir / root.name for root in roots)) + list(copied.values())
    for target in all_targets:
        if target.parent == lib_dir:
            subprocess.run(
                ["install_name_tool", "-id", f"@loader_path/{target.name}", str(target)],
                check=True,
                stderr=subprocess.DEVNULL,
            )
        for old_name, source in dependencies(target):
            destination = copied.get(source.resolve())
            if destination is None:
                continue
            replacement = (
                f"@loader_path/../lib/{destination.name}"
                if target.parent == bin_dir
                else f"@loader_path/{destination.name}"
            )
            subprocess.run(
                ["install_name_tool", "-change", old_name, replacement, str(target)],
                check=True,
                stderr=subprocess.DEVNULL,
            )
        os.chmod(target, 0o755)

    print(f"Bundled ffmpeg, ffprobe, and {len(copied)} libraries")


if __name__ == "__main__":
    main()
