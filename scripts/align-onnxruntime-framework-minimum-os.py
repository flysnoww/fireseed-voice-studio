#!/usr/bin/env python3
"""Correct stale ONNX framework plist MinimumOSVersion from its Mach-O load command."""

from __future__ import annotations

import pathlib
import plistlib
import re
import subprocess
import sys


def run(*args: str) -> str:
    result = subprocess.run(args, check=True, text=True, capture_output=True)
    return result.stdout.strip()


def main(framework: pathlib.Path) -> None:
    info_path = framework / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    executable = framework / info.get("CFBundleExecutable", framework.stem)
    archs = run("lipo", "-archs", str(executable)).split()
    if "arm64" not in archs or any(arch not in {"arm64", "arm64e"} for arch in archs):
        raise SystemExit(f"Unexpected ONNX Runtime iOS device architectures: {archs}")

    mins: list[str] = []
    for arch in archs:
        build = run("xcrun", "vtool", "-arch", arch, "-show-build", str(executable))
        platform = re.search(r"^\s*platform\s+(\S+)", build, re.MULTILINE)
        minimum = re.search(r"^\s*minos\s+(\S+)", build, re.MULTILINE)
        if not platform or platform.group(1) != "IOS" or not minimum:
            raise SystemExit(f"ONNX Runtime {arch} is not a verifiable iOS device binary:\n{build}")
        mins.append(minimum.group(1))

    actual_min = max(mins, key=lambda item: tuple(int(part) for part in item.split(".")))
    original = info.get("MinimumOSVersion")
    if original != actual_min:
        print(f"Aligning ONNX Runtime framework MinimumOSVersion {original!r} -> {actual_min} from LC_BUILD_VERSION")
        info["MinimumOSVersion"] = actual_min
        info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=True))
    else:
        print(f"ONNX Runtime framework MinimumOSVersion already matches LC_BUILD_VERSION: {actual_min}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: align-onnxruntime-framework-minimum-os.py <onnxruntime.framework>")
    main(pathlib.Path(sys.argv[1]))
