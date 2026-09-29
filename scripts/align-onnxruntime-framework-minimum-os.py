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


def framework_plist_minimum(source_mins: list[str], app_minimum: str) -> str:
    if not source_mins:
        raise ValueError("ONNX Runtime framework has no verifiable binary minimum OS version")
    incompatible = [value for value in source_mins if version_tuple(value) > version_tuple(app_minimum)]
    if incompatible:
        raise ValueError(
            f"ONNX Runtime source binary minOS {max(incompatible, key=version_tuple)} "
            f"exceeds VoiceStudio deployment target {app_minimum}"
        )
    # The SPM artifact is a static archive. Xcode creates the embedded framework
    # wrapper for the app target, whose Mach-O minOS is the app deployment target.
    return app_minimum


def main(framework: pathlib.Path, app_minimum: str) -> None:
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

    try:
        embedded_minimum = framework_plist_minimum(mins, app_minimum)
    except ValueError as error:
        raise SystemExit(str(error)) from error
    original = info.get("MinimumOSVersion")
    if original != embedded_minimum:
        print(
            f"Aligning static ONNX Runtime framework wrapper MinimumOSVersion "
            f"{original!r} -> {embedded_minimum} from VoiceStudio deployment target "
            f"(source archive minOS {max(mins, key=version_tuple)})"
        )
        info["MinimumOSVersion"] = embedded_minimum
        info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=True))
    else:
        print(f"ONNX Runtime framework wrapper MinimumOSVersion already matches app target: {embedded_minimum}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: align-onnxruntime-framework-minimum-os.py <onnxruntime.framework> <app-minimum-os>")
    main(pathlib.Path(sys.argv[1]), sys.argv[2])
