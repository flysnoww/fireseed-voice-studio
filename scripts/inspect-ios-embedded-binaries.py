#!/usr/bin/env python3
"""Audit embedded iOS frameworks and dylibs against an app's deployment target."""

from __future__ import annotations

import argparse
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


def find_app_executable(app: pathlib.Path) -> pathlib.Path:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    return app / info["CFBundleExecutable"]


def audit(app: pathlib.Path) -> int:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    app_min = info.get("MinimumOSVersion")
    if not app_min:
        raise SystemExit(f"App Info.plist missing MinimumOSVersion: {app}")
    print(f"APP: {app} MinimumOSVersion={app_min}")
    app_binary = find_app_executable(app)
    print(f"APP_BINARY: {app_binary}")
    print(run("file", str(app_binary)))
    print(run("lipo", "-info", str(app_binary)))
    print(run("otool", "-l", str(app_binary)))
    app_builds = read_build_metadata(str(app_binary), "arm64")
    app_platforms = {build.platform for build in app_builds}
    app_binary_min = max((build.minos for build in app_builds), key=version_tuple)
    print(f"APP_BUILD_METADATA: {app_builds}")
    if app_platforms != {"IOS"}:
        raise SystemExit(f"App binary is not an iOS device binary: {sorted(app_platforms)}")
    if version_tuple(app_binary_min) > version_tuple(app_min):
        raise SystemExit(f"App binary minOS {app_binary_min} exceeds app Info.plist minOS {app_min}")

    targets: list[tuple[pathlib.Path, pathlib.Path | None, str]] = []
    for framework in sorted(app.rglob("*.framework")):
        framework_info = framework / "Info.plist"
        plist = plistlib.loads(framework_info.read_bytes()) if framework_info.is_file() else {}
        executable_name = plist.get("CFBundleExecutable", framework.stem)
        binary = framework / executable_name
        if binary.is_file():
            targets.append((binary, framework_info if framework_info.is_file() else None, str(framework)))
    for dylib in sorted(app.rglob("*.dylib")):
        if not any(dylib == item[0] for item in targets):
            targets.append((dylib, None, str(dylib)))

    failures: list[str] = []
    if not targets:
        failures.append("No embedded frameworks or dylibs were found")

    for binary, plist_path, label in targets:
        print(f"\n=== EMBEDDED_BINARY: {label} ===")
        if plist_path:
            raw_plist = run("plutil", "-p", str(plist_path))
            print(f"INFO_PLIST: {raw_plist}")
            framework_info = plistlib.loads(plist_path.read_bytes())
            supported = framework_info.get("CFBundleSupportedPlatforms")
            framework_min = framework_info.get("MinimumOSVersion")
            dt_platform = framework_info.get("DTPlatformVersion")
            dt_sdk = framework_info.get("DTSDKName")
            print(f"CFBundleSupportedPlatforms={supported!r} MinimumOSVersion={framework_min!r} DTPlatformVersion={dt_platform!r} DTSDKName={dt_sdk!r}")
            if supported and "iPhoneOS" not in supported:
                failures.append(f"{label}: unsupported plist platform {supported!r}")
            if dt_sdk and not dt_sdk.lower().startswith("iphoneos"):
                failures.append(f"{label}: DTSDKName is not an iPhoneOS SDK: {dt_sdk}")
            if not framework_min:
                failures.append(f"{label}: framework Info.plist is missing MinimumOSVersion")
            if framework_min and version_tuple(framework_min) > version_tuple(app_min):
                failures.append(f"{label}: plist minOS {framework_min} exceeds app minOS {app_min}")
        else:
            print("INFO_PLIST: none (dylib)")

        print(run("file", str(binary)))
        arch_output = run("lipo", "-archs", str(binary))
        print(f"ARCHS: {arch_output}")
        architectures = arch_output.split()
        if not architectures:
            failures.append(f"{label}: no readable Mach-O architectures")
        binary_mins: list[str] = []
        for arch in architectures:
            load_commands = run("otool", "-arch", arch, "-l", str(binary))
            builds = read_build_metadata(str(binary), arch)
            summary: dict[tuple[str, str, str | None], int] = {}
            for build in builds:
                key = (build.platform, build.minos, build.sdk)
                summary[key] = summary.get(key, 0) + 1
            print(f"BUILD_METADATA arch={arch} load_commands={load_commands.count('Load command ')} build_metadata_entries={len(builds)} unique_platform_minos_sdk={summary}")
            platforms = {build.platform for build in builds}
            if platforms != {"IOS"}:
                failures.append(f"{label} ({arch}): platforms are {sorted(platforms)}, expected IOS device")
            if arch not in {"arm64", "arm64e"}:
                failures.append(f"{label} ({arch}): architecture is not supported for iPhone device distribution")
            for build in builds:
                binary_mins.append(build.minos)
                if version_tuple(build.minos) > version_tuple(app_min):
                    failures.append(f"{label} ({arch}): binary minOS {build.minos} exceeds app minOS {app_min}")

        if plist_path and binary_mins and framework_min:
            actual_min = max(binary_mins, key=version_tuple)
            if version_tuple(framework_min) != version_tuple(actual_min):
                failures.append(f"{label}: Info.plist MinimumOSVersion {framework_min} disagrees with binary minOS {actual_min}")

    if failures:
        print("\nCOMPATIBILITY AUDIT FAILED:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print("\nCOMPATIBILITY AUDIT PASSED")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=pathlib.Path, help="Path to extracted .app bundle")
    raise SystemExit(audit(parser.parse_args().app))
