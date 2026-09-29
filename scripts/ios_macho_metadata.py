#!/usr/bin/env python3
"""Read iOS build metadata from Mach-O binaries and static archives using otool."""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass


@dataclass(frozen=True)
class BuildMetadata:
    platform: str
    minos: str
    sdk: str | None


def run(*args: str) -> str:
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(
            f"Command failed ({result.returncode}): {' '.join(args)}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result.stdout.strip()


def parse_otool_build_commands(output: str) -> list[BuildMetadata]:
    """Parse every LC_BUILD_VERSION / LC_VERSION_MIN command, including archive members."""
    records: list[BuildMetadata] = []
    blocks = re.split(r"(?=^Load command \d+\s*$)", output, flags=re.MULTILINE)
    for block in blocks:
        command = re.search(r"^\s*cmd\s+(LC_[A-Z0-9_]+)\s*$", block, re.MULTILINE)
        if not command:
            continue
        name = command.group(1)
        if name == "LC_BUILD_VERSION":
            platform = re.search(r"^\s*platform\s+(\S+)\s*$", block, re.MULTILINE)
            minimum = re.search(r"^\s*minos\s+(\S+)\s*$", block, re.MULTILINE)
            sdk = re.search(r"^\s*sdk\s+(\S+)\s*$", block, re.MULTILINE)
            if platform and minimum:
                platform_name = {
                    "1": "MACOS",
                    "2": "IOS",
                    "3": "TVOS",
                    "4": "WATCHOS",
                    "5": "BRIDGEOS",
                    "6": "MACCATALYST",
                    "7": "IOSSIMULATOR",
                    "8": "TVOSSIMULATOR",
                    "9": "WATCHOSSIMULATOR",
                    "10": "DRIVERKIT",
                    "11": "VISIONOS",
                    "12": "VISIONOSSIMULATOR",
                }.get(platform.group(1), platform.group(1))
                records.append(BuildMetadata(platform_name, minimum.group(1), sdk.group(1) if sdk else None))
        elif name.startswith("LC_VERSION_MIN_"):
            target = name.removeprefix("LC_VERSION_MIN_")
            platform = {
                "IPHONEOS": "IOS",
                "IPHONESIMULATOR": "IOSSIMULATOR",
                "MACOSX": "MACOS",
                "TVOS": "TVOS",
                "TVOSSIMULATOR": "TVOSSIMULATOR",
                "WATCHOS": "WATCHOS",
                "WATCHOSSIMULATOR": "WATCHOSSIMULATOR",
            }.get(target, target)
            minimum = re.search(r"^\s*version\s+(\S+)\s*$", block, re.MULTILINE)
            sdk = re.search(r"^\s*sdk\s+(\S+)\s*$", block, re.MULTILINE)
            if minimum:
                records.append(BuildMetadata(platform, minimum.group(1), sdk.group(1) if sdk else None))
    return records


def read_build_metadata(binary: str, arch: str) -> list[BuildMetadata]:
    output = run("otool", "-arch", arch, "-l", binary)
    records = parse_otool_build_commands(output)
    if not records:
        raise RuntimeError(f"No LC_BUILD_VERSION or LC_VERSION_MIN command found for {arch}: {binary}")
    return records


def version_tuple(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in value.split("."))
