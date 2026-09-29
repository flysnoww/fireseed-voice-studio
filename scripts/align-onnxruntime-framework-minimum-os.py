#!/usr/bin/env python3
"""Correct stale ONNX framework plist MinimumOSVersion from its Mach-O load command."""

from __future__ import annotations

import pathlib
import plistlib
import sys

from ios_macho_metadata import read_build_metadata, version_tuple


def run(*args: str) -> str:
    from ios_macho_metadata import run as run_command

    try:
        return run_command(*args)
    except RuntimeError as error:
        raise SystemExit(str(error)) from error


def main(framework: pathlib.Path) -> None:
    info_path = framework / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    executable = framework / info.get("CFBundleExecutable", framework.stem)
    archs = run("lipo", "-archs", str(executable)).split()
    if "arm64" not in archs or any(arch not in {"arm64", "arm64e"} for arch in archs):
        raise SystemExit(f"Unexpected ONNX Runtime iOS device architectures: {archs}")
    print(run("file", str(executable)))
    print(f"ONNX Runtime framework architectures: {archs}")

    mins: list[str] = []
    for arch in archs:
        try:
            builds = read_build_metadata(str(executable), arch)
        except RuntimeError as error:
            raise SystemExit(str(error)) from error
        platforms = {build.platform for build in builds}
        if platforms != {"IOS"}:
            raise SystemExit(f"ONNX Runtime {arch} contains non-iOS build metadata: {sorted(platforms)}")
        metadata_summary = sorted({(build.platform, build.minos, build.sdk) for build in builds})
        print(f"ONNX Runtime {arch} build metadata entries={len(builds)} platform/minOS/SDK={metadata_summary}")
        mins.extend(build.minos for build in builds)

    actual_min = max(mins, key=version_tuple)
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
