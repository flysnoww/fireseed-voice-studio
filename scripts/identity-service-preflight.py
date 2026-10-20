#!/usr/bin/env python3
"""No-login VoiceStudio OIDC preflight. Never acquires or prints user credentials."""
import argparse
import base64
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import secrets
import urllib.error
import urllib.parse
import urllib.request

ISSUER = 'https://auth.fireseed.work/oidc'
CLIENT = 'ghducpbvjml6ovk92e392'
CALLBACK = 'com.fireseed.voicestudio://oauth/callback'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def validate_discovery(info):
    require(info.get('issuer') == ISSUER, 'Unexpected OIDC issuer')
    require('S256' in info.get('code_challenge_methods_supported', []), 'PKCE S256 unavailable')
    for key in ('authorization_endpoint', 'token_endpoint', 'jwks_uri', 'userinfo_endpoint', 'end_session_endpoint'):
        require(info.get(key, '').startswith(ISSUER + '/'), 'Unexpected OIDC endpoint: ' + key)


def validate_no_login_callback(location, state):
    url = urllib.parse.urlsplit(location)
    expected = urllib.parse.urlsplit(CALLBACK)
    require((url.scheme, url.netloc, url.path, url.fragment) == (expected.scheme, expected.netloc, expected.path, ''),
            'Unexpected authorization callback')
    query = urllib.parse.parse_qs(url.query)
    require(query.get('state') == [state], 'Authorization state mismatch')
    require(query.get('error') == ['login_required'] and 'code' not in query, 'Expected unauthenticated login_required')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def preflight(info_path):
    info = plistlib.loads(info_path.read_bytes())
    require(info.get('FireseedIdentityIssuer') == ISSUER and info.get('FireseedIdentityClientID') == CLIENT and
            info.get('FireseedIdentityRedirectURI') == CALLBACK, 'Wrong VoiceStudio Identity configuration')
    with urllib.request.urlopen(ISSUER + '/.well-known/openid-configuration', timeout=20) as response:
        discovery = json.load(response)
    validate_discovery(discovery)
    with urllib.request.urlopen(discovery['jwks_uri'], timeout=20) as response:
        keys = json.load(response).get('keys', [])
    require(len(keys) > 0, 'Empty OIDC JWKS')
    state = secrets.token_urlsafe(32)
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
    query = urllib.parse.urlencode(dict(client_id=CLIENT, redirect_uri=CALLBACK, response_type='code',
        scope='openid profile offline_access', code_challenge=challenge, code_challenge_method='S256', state=state, prompt='none'))
    try:
        response = urllib.request.build_opener(NoRedirect).open(discovery['authorization_endpoint'] + '?' + query, timeout=20)
    except urllib.error.HTTPError as error:
        response = error
    require(response.code in (302, 303), 'Expected no-login OIDC redirect')
    validate_no_login_callback(response.headers.get('Location', ''), state)
    return {'status': 'PASS', 'scope': 'LIVE_DISCOVERY_AND_NO_LOGIN_AUTHORIZATION_ONLY',
            'issuer': ISSUER, 'client': CLIENT, 'callback': CALLBACK, 'pkce': 'S256',
            'jwks_key_count': len(keys), 'state_verified': True, 'result': 'login_required',
            'real_apple_google_login': 'NOT TESTED', 'observed_utc': datetime.datetime.now(datetime.timezone.utc).isoformat()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--info-plist', type=Path, default=Path(__file__).resolve().parents[1] / 'ios/VoiceStudioApp/Info.plist')
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    # Exceptions contain fixed diagnostic messages, never full redirect/token data.
    try:
        result = preflight(args.info_plist)
    except Exception as error:
        result = {'status': 'FAIL', 'error_type': type(error).__name__}
        args.report.write_text(json.dumps(result, indent=2))
        print('Identity service preflight failed; no credentials were acquired.')
        raise SystemExit(1)
    args.report.write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
