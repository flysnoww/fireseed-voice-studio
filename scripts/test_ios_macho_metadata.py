#!/usr/bin/env python3
from __future__ import annotations

import unittest

from ios_macho_metadata import parse_otool_build_commands


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


if __name__ == "__main__":
    unittest.main()
