#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest

from ios_macho_metadata import parse_otool_build_commands

_ALIGN_PATH = pathlib.Path(__file__).with_name("align-onnxruntime-framework-minimum-os.py")
_ALIGN_SPEC = importlib.util.spec_from_file_location("align_onnxruntime_framework_minimum_os", _ALIGN_PATH)
assert _ALIGN_SPEC and _ALIGN_SPEC.loader
_ALIGN_MODULE = importlib.util.module_from_spec(_ALIGN_SPEC)
sys.modules[_ALIGN_SPEC.name] = _ALIGN_MODULE
_ALIGN_SPEC.loader.exec_module(_ALIGN_MODULE)
framework_plist_minimum = _ALIGN_MODULE.framework_plist_minimum


class OtoolBuildMetadataTests(unittest.TestCase):
    def test_reads_each_build_command_in_static_archive(self) -> None:
        output = """Archive : libonnxruntime.a
member-one.o:
Load command 1
          cmd LC_BUILD_VERSION
      cmdsize 32
     platform IOS
        minos 17.0
          sdk 26.5
      ntools 0
member-two.o:
Load command 3
          cmd LC_BUILD_VERSION
      cmdsize 32
     platform IOS
        minos 16.0
          sdk 26.5
      ntools 0
"""
        records = parse_otool_build_commands(output)
        self.assertEqual([(item.platform, item.minos, item.sdk) for item in records], [
            ("IOS", "17.0", "26.5"),
            ("IOS", "16.0", "26.5"),
        ])

    def test_reads_legacy_iphoneos_minimum_command(self) -> None:
        output = """Load command 5
          cmd LC_VERSION_MIN_IPHONEOS
      cmdsize 16
      version 15.1
          sdk 17.2
"""
        records = parse_otool_build_commands(output)
        self.assertEqual([(item.platform, item.minos, item.sdk) for item in records], [
            ("IOS", "15.1", "17.2"),
        ])

    def test_distinguishes_simulator_platform(self) -> None:
        output = """Load command 0
          cmd LC_BUILD_VERSION
      cmdsize 32
     platform IOSSIMULATOR
        minos 17.0
          sdk 26.5
      ntools 0
"""
        records = parse_otool_build_commands(output)
        self.assertEqual(records[0].platform, "IOSSIMULATOR")

    def test_maps_numeric_platform_constants_from_archive_output(self) -> None:
        output = """Load command 0
          cmd LC_BUILD_VERSION
      cmdsize 32
     platform 2
        minos 17.0
          sdk 26.5
      ntools 0
"""
        records = parse_otool_build_commands(output)
        self.assertEqual(records[0].platform, "IOS")

    def test_static_framework_wrapper_uses_app_target_when_source_is_compatible(self) -> None:
        self.assertEqual(framework_plist_minimum(["15.1", "15.1"], "17.0"), "17.0")

    def test_rejects_source_archive_newer_than_app_target(self) -> None:
        with self.assertRaisesRegex(ValueError, "exceeds VoiceStudio deployment target"):
            framework_plist_minimum(["17.1"], "17.0")

    def test_rejects_missing_source_minimum(self) -> None:
        with self.assertRaisesRegex(ValueError, "no verifiable binary minimum"):
            framework_plist_minimum([], "17.0")


if __name__ == "__main__":
    unittest.main()
