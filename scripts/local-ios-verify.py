#!/usr/bin/env python3
"""Verify the actual archived/exported VoiceStudio app, without uploading."""
import argparse
import datetime
import hashlib
import json
import pathlib
import plistlib
import subprocess

BUNDLE = 'com.fireseed.voicestudio'
TEAM = 'Z36ZADH7T7'
PROFILE = 'fa3f93de-933a-493c-be0a-3e85c0a66c69'
IDENTITY = 'F0B896DA427C62C17DDFFFE84F6B08A57A5E159D'



def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def output(*args):
    return subprocess.check_output(args)


def verify(app, version, build):
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    require(info['CFBundleIdentifier'] == BUNDLE, 'Wrong bundle')
    require(info['CFBundleShortVersionString'] == version, 'Wrong version')
    require(info['CFBundleVersion'] == build, 'Wrong build')
    require(info['UIDeviceFamily'] == [1], 'Expected iPhone only')
    require(info['MinimumOSVersion'] == '17.0', 'Unexpected minimum OS')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)], check=True)
    signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], check=True, capture_output=True).stderr.decode()
    require('TeamIdentifier=' + TEAM in signature, "Validation failed: 'TeamIdentifier=' + TEAM in signature")
    require('Authority=Apple Distribution:' in signature, "Validation failed: 'Authority=Apple Distribution:' in signature")
    ent = plistlib.loads(output('codesign', '-d', '--entitlements', ':-', str(app)))
    require(ent['application-identifier'] == TEAM + '.' + BUNDLE, "Validation failed: ent['application-identifier'] == TEAM + '.' + BUNDLE")
    require(ent['com.apple.developer.team-identifier'] == TEAM, "Validation failed: ent['com.apple.developer.team-identifier'] == TEAM")
    require(ent['get-task-allow'] is False, "Validation failed: ent['get-task-allow'] is False")
    profile = plistlib.loads(output('security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')))
    require(profile['UUID'] == PROFILE, "Validation failed: profile['UUID'] == PROFILE")
    require(profile['Name'] == 'Voice Studio App Store Distribution', "Validation failed: profile['Name'] == 'Voice Studio App Store Distribution'")
    require(profile['TeamIdentifier'] == [TEAM], "Validation failed: profile['TeamIdentifier'] == [TEAM]")
    require(profile['ExpirationDate'] > datetime.datetime.utcnow(), "Validation failed: profile['ExpirationDate'] > datetime.datetime.utcnow()")
    require(profile['Entitlements']['application-identifier'] == TEAM + '.' + BUNDLE, "Validation failed: profile['Entitlements']['application-identifier'] == TEAM + '.' + BUNDLE")
    require(profile['Entitlements']['get-task-allow'] is False, "Validation failed: profile['Entitlements']['get-task-allow'] is False")
    require('ProvisionedDevices' not in profile and not profile.get('ProvisionsAllDevices', False), "Validation failed: 'ProvisionedDevices' not in profile and not profile.get('ProvisionsAllDevices', False)")
    require(any(hashlib.sha1(cert).hexdigest().upper() == IDENTITY for cert in profile['DeveloperCertificates']), "Validation failed: any(hashlib.sha1(cert).hexdigest().upper() == IDENTITY for cert in profile['DeveloperCertificates'])")
    # Compare the actual leaf signing certificate with the profile, not just its common name.
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        prefix = str(pathlib.Path(tmp) / 'cert')
        subprocess.run(['codesign', '-d', '--extract-certificates=' + prefix, str(app)], check=True)
        leaf = pathlib.Path(prefix + '0').read_bytes()
        require(leaf in profile['DeveloperCertificates'], 'Actual signer absent from profile')
    subprocess.run(['python3', 'scripts/inspect-ios-embedded-binaries.py', str(app)], check=True)
    assets = json.loads(output('xcrun', 'assetutil', '--info', str(app / 'Assets.car')))
    require(any(item.get('Name') == 'AppIcon' for item in assets), "Validation failed: any(item.get('Name') == 'AppIcon' for item in assets)")
    frameworks = sorted(p.name for p in (app / 'Frameworks').glob('*.framework'))
    for fw in (app / 'Frameworks').glob('*.framework'):
        subprocess.run(['codesign', '--verify', '--strict', str(fw)], check=True)
    return {'bundle': BUNDLE, 'team': TEAM, 'version': version, 'build': build,
            'profile_uuid': profile['UUID'], 'profile_expiration_utc': str(profile['ExpirationDate']),
            'minimum_os': info['MinimumOSVersion'], 'frameworks': frameworks,
            'entitlements': ent, 'signature': signature, 'status': 'PASS'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=pathlib.Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--report', type=pathlib.Path, required=True)
    args = parser.parse_args()
    args.report.write_text(json.dumps(verify(args.app, args.version, args.build), indent=2))
