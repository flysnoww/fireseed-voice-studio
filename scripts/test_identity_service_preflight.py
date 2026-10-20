import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('identity_preflight', Path(__file__).with_name('identity-service-preflight.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class IdentityServicePreflightTests(unittest.TestCase):
    def test_correct_unauthenticated_callback(self):
        module.validate_no_login_callback(module.CALLBACK + '?state=fixture&error=login_required', 'fixture')

    def test_rejects_wrong_state_and_callback(self):
        for uri in [module.CALLBACK + '?state=wrong&error=login_required',
                    'com.other://oauth/callback?state=fixture&error=login_required',
                    module.CALLBACK + '-other?state=fixture&error=login_required']:
            with self.assertRaises(RuntimeError): module.validate_no_login_callback(uri, 'fixture')

    def test_never_accepts_an_unexpected_authorization_code(self):
        with self.assertRaises(RuntimeError):
            module.validate_no_login_callback(module.CALLBACK + '?state=fixture&code=synthetic', 'fixture')

    def test_discovery_rejects_wrong_issuer_or_external_endpoint(self):
        info = {'issuer': module.ISSUER, 'code_challenge_methods_supported': ['S256']}
        for key in ['authorization_endpoint', 'token_endpoint', 'jwks_uri', 'userinfo_endpoint', 'end_session_endpoint']:
            info[key] = module.ISSUER + '/endpoint'
        module.validate_discovery(info)
        for key, value in [('issuer', 'https://other.example/oidc'), ('jwks_uri', 'https://other.example/keys'), ('code_challenge_methods_supported', ['plain'])]:
            broken = dict(info); broken[key] = value
            with self.assertRaises(RuntimeError): module.validate_discovery(broken)
