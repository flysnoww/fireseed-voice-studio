"""Exercise the release CLI's external upload and overwrite boundaries without Xcode."""
from pathlib import Path
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('local-ios-release.py')


class ReleaseSafetyTests(unittest.TestCase):
    def invoke(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True)

    def test_default_dry_run_has_no_output_side_effects(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / 'release'
            result = self.invoke('--output', str(out))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(out.exists())
            plan = json.loads(result.stdout)
            self.assertFalse(plan['upload'])
            self.assertEqual(plan['upload_mode'], 'xcode-account')
            self.assertEqual(plan['bundle'], 'com.fireseed.voicestudio')
            self.assertIn('App XCTest + all UI tests', plan['stages'])

    def test_xcode_account_upload_plan_stays_dry_without_execute(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / 'release'
            result = self.invoke('--upload', '--upload-mode', 'xcode-account', '--build-number', '7',
                                 '--confirmed-unused-build', '--upload-authorization',
                                 'UPLOAD com.fireseed.voicestudio 0.1 (7)', '--output', str(out))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(out.exists())
            plan = json.loads(result.stdout)
            self.assertEqual(plan['mode'], 'DRY-RUN')
            self.assertTrue(plan['upload'])
            self.assertIn('destination=upload', plan['stages'][-1])

    def test_upload_refuses_missing_or_wrong_authorization(self):
        for extra in [['--build-number', '2'], ['--build-number', '2', '--confirmed-unused-build'],
                      ['--build-number', '2', '--confirmed-unused-build', '--upload-authorization', 'UPLOAD org.tmiai.aiquicknote 0.1 (2)']]:
            with self.subTest(extra=extra):
                result = self.invoke('--execute', '--upload', *extra)
                self.assertEqual(result.returncode, 2)
                self.assertIn('explicit exact authorization', result.stderr)

    def test_upload_refuses_local_build_one_even_with_exact_authorization(self):
        result = self.invoke('--execute', '--upload', '--build-number', '1', '--confirmed-unused-build',
                             '--upload-authorization', 'UPLOAD com.fireseed.voicestudio 0.1 (1)')
        self.assertEqual(result.returncode, 2)
        self.assertIn('Build 1 is reserved for local validation', result.stderr)

    def test_upload_requires_explicit_build_number(self):
        result = self.invoke('--execute', '--upload', '--confirmed-unused-build',
                             '--upload-authorization', 'UPLOAD com.fireseed.voicestudio 0.1 (1)')
        self.assertEqual(result.returncode, 2)
        self.assertIn('explicitly supplied App Store Connect confirmed-unused build number', result.stderr)

    def test_authorization_does_not_imply_execute(self):
        result = self.invoke('--upload', '--build-number', '2', '--confirmed-unused-build', '--upload-authorization', 'UPLOAD com.fireseed.voicestudio 0.1 (2)')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['mode'], 'DRY-RUN')

    def test_invalid_versions_rejected_before_work(self):
        for value in ['0', '-1', '1;touch /tmp/should-not-exist', '../2']:
            result = self.invoke('--execute', '--build-number', value)
            self.assertEqual(result.returncode, 2)

    def test_existing_output_is_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            sentinel = Path(temp) / 'sentinel'
            sentinel.write_text('preserve')
            result = self.invoke('--execute', '--output', temp)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(sentinel.read_text(), 'preserve')

    def test_export_compliance_preflight_requires_boolean_false(self):
        verifier = Path(__file__).with_name('local-ios-verify.py')
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / 'VoiceStudio.app'
            app.mkdir()
            info = {'CFBundleIdentifier': 'com.fireseed.voicestudio',
                    'ITSAppUsesNonExemptEncryption': False}
            plist = app / 'Info.plist'
            for value, expected in [(False, 0), (True, 1), ('false', 1), (None, 1)]:
                if value is None:
                    info.pop('ITSAppUsesNonExemptEncryption', None)
                else:
                    info['ITSAppUsesNonExemptEncryption'] = value
                plist.write_bytes(plistlib.dumps(info))
                report = Path(temp) / 'compliance.json'
                result = subprocess.run([sys.executable, str(verifier), str(app),
                                         '--check-export-compliance-only', '--report', str(report)],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)
                if expected == 0:
                    self.assertFalse(json.loads(report.read_text())['ITSAppUsesNonExemptEncryption'])

if __name__ == '__main__':
    unittest.main()
