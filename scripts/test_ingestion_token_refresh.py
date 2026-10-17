import base64
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('ingestion', Path(__file__).with_name('verify-appstore-build-ingestion.py'))
ingestion = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ingestion)


class IngestionTokenTests(unittest.TestCase):
    def test_processing_refreshes_auth_and_cleans_temporary_key(self):
        with tempfile.TemporaryDirectory() as temp:
            argv = ['verify', '--key-id', 'TEST', '--issuer-id', 'test-issuer', '--bundle-id', 'com.fireseed.voicestudio', '--version', '0.1', '--build-number', '9']
            apps = {'data': [{'id': '6816751639', 'attributes': {'bundleId': 'com.fireseed.voicestudio'}}]}
            processing = {'data': [{'id': 'test-build', 'attributes': {'version': '9', 'processingState': 'PROCESSING'}}]}
            valid = {'data': [{'id': 'test-build', 'attributes': {'version': '9', 'processingState': 'VALID'}}]}
            env = {'RUNNER_TEMP': temp, 'API_PRIVATE_KEY_BASE64': base64.b64encode(b'fake-test-key').decode()}
            with patch('sys.argv', argv), patch.dict(os.environ, env), patch.object(ingestion, 'jwt_token', side_effect=['app-token', 'poll-token-1', 'poll-token-2']) as jwt, patch.object(ingestion, 'get_json', side_effect=[apps, {'data': []}, processing, {'data': []}, valid]) as get, patch.object(ingestion.time, 'sleep'):
                self.assertEqual(ingestion.main(), 0)
                self.assertEqual(jwt.call_count, 3)
                self.assertEqual([call.args[1] for call in get.call_args_list], ['app-token', 'poll-token-1', 'poll-token-1', 'poll-token-2', 'poll-token-2'])
            self.assertFalse((Path(temp) / 'voice-studio-asc-ingestion-key.p8').exists())
