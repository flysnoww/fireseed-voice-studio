#!/usr/bin/env python3
"""VoiceStudio local release. Dry-run by default; upload is separately gated."""
import argparse
import base64
import tempfile
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.fireseed.voicestudio'
TEAM = 'Z36ZADH7T7'
PROFILE = 'Voice Studio App Store Distribution'
IDENTITY = 'F0B896DA427C62C17DDFFFE84F6B08A57A5E159D'



def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--execute', action='store_true', help='Perform tests/build/archive/export locally')
    mode.add_argument('--dry-run', action='store_true', help='Print plan; no writes or subprocesses')
    parser.add_argument('--version', default='0.1')
    parser.add_argument('--build-number', help='ASC-confirmed unused build for upload; local validation defaults to tracked 1')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--simulator-id', help='Explicit available iPhone UDID; otherwise use CI first-iPhone selection')
    parser.add_argument('--upload', action='store_true')
    parser.add_argument('--upload-mode', choices=('xcode-account', 'api-key'), default='xcode-account',
                        help='Use the Xcode signed-in account (default) or the existing App Store Connect API-key route')
    parser.add_argument('--upload-authorization', help='Exact phrase: UPLOAD com.fireseed.voicestudio VERSION (BUILD)')
    parser.add_argument('--confirmed-unused-build', action='store_true', help='Operator has checked ASC including failed/processing uploads')
    args = parser.parse_args()
    upload_build_explicit = args.build_number is not None
    if args.build_number is None:
        args.build_number = '1'
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', args.version) or not re.fullmatch(r'[1-9][0-9]*', args.build_number):
        parser.error('Invalid version/build')
    phrase = 'UPLOAD {} {} ({})'.format(BUNDLE, args.version, args.build_number)
    if args.upload and not upload_build_explicit:
        parser.error('Upload requires an explicitly supplied App Store Connect confirmed-unused build number')
    if args.upload and args.build_number == '1':
        parser.error('Build 1 is reserved for local validation and cannot be uploaded')
    if args.upload and (not args.confirmed_unused_build or args.upload_authorization != phrase):
        parser.error('Upload requires explicit exact authorization and confirmed unused build')
    out = (args.output or ROOT / 'local-releases' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S')).resolve()
    if out.exists():
        parser.error('Output already exists; never overwrite release evidence')
    if not args.execute:
        print(json.dumps({'mode': 'DRY-RUN', 'output': str(out), 'bundle': BUNDLE, 'team': TEAM,
                          'profile': PROFILE, 'version': args.version, 'build': args.build_number,
                          'upload_mode': args.upload_mode,
                          'stages': ['Core/Node/Python tests', 'pinned simulator runtime', 'Debug build',
                                     'install verified OpenVoice fixture', 'App XCTest + all UI tests',
                                     'pinned device runtime', 'Release build', 'ORT minimum OS alignment',
                                     'manual Distribution archive', 'archive signature/metadata verification',
                                     'exportArchive (destination=export)', 'IPA preflight',
                                     ('xcodebuild exportArchive (method=app-store-connect, destination=upload)'
                                      if args.upload_mode == 'xcode-account' else 'authorized API-key upload + Apple processing query')
                                     if args.upload else 'STOP: no upload'],
                          'upload': args.upload, 'simulator_id': args.simulator_id}, indent=2))
        return 0
    os.chdir(ROOT)
    if args.upload and args.upload_mode == 'api-key':
        for key in ('API_KEY_ID', 'API_ISSUER_ID', 'API_PRIVATE_KEY_BASE64'):
            if not os.environ.get(key):
                parser.error('Missing credential environment variable: ' + key)
    out.mkdir(parents=True)
    state = {'version': args.version, 'build': args.build_number, 'bundle': BUNDLE,
             'team': TEAM, 'upload_authorized': args.upload, 'upload_mode': args.upload_mode, 'uploaded': False,
             'status': 'RUNNING', 'stages': [], 'started_utc': datetime.datetime.utcnow().isoformat() + 'Z'}
    def save():
        (out / 'result.json').write_text(json.dumps(state, indent=2))
    def run(name, cmd, env=None, cwd=None):
        print(name + ': ' + shlex.join([str(x) for x in cmd]), flush=True)
        with (out / (name + '.log')).open('w') as log:
            result = subprocess.run([str(x) for x in cmd], stdout=log, stderr=subprocess.STDOUT, env=env, cwd=cwd)
        state['stages'].append({'name': name, 'exit_code': result.returncode})
        save()
        if result.returncode:
            raise RuntimeError(name + ' failed; inspect ' + str(out / (name + '.log')))
    try:
        state['git_head'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
        state['git_diff_sha256'] = hashlib.sha256(subprocess.check_output(['git', 'diff', 'HEAD'])).hexdigest()
        run('core-tests', ['swift', 'test', '--package-path', 'ios/VoiceStudioCore', '-Xswiftc', '-strict-concurrency=complete'])
        run('node-tests', ['npm', 'test'])
        run('python-tests', ['python3', '-m', 'unittest', 'discover', '-s', 'scripts', '-p', 'test*.py'])
        run('runtime-simulator', ['bash', 'experiments/m2b-qwen-ios/scripts/build_formal_ios_runtime.sh', 'simulator'])
        derived = out / 'DerivedData'
        xcode = ['xcodebuild', '-project', 'ios/VoiceStudio.xcodeproj', '-scheme', 'VoiceStudio', '-derivedDataPath', derived]
        run('resolve-packages', xcode + ['-resolvePackageDependencies'])
        run('kitten-manifest-compatibility', ['python3', 'scripts/prepare-local-kitten-package.py', derived])
        run('debug-build', xcode + ['-sdk', 'iphonesimulator', '-configuration', 'Debug', 'CODE_SIGNING_ALLOWED=NO', 'ARCHS=arm64', 'build'])
        run('debug-export-compliance', ['python3', 'scripts/local-ios-verify.py',
                                        derived / 'Build/Products/Debug-iphonesimulator/VoiceStudio.app',
                                        '--check-export-compliance-only', '--report', out / 'debug-export-compliance.json'])
        devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
        candidates = [d for runtime in devices.values() for d in runtime if d['name'].startswith('iPhone') or d['udid'] == args.simulator_id]
        device = next(d for d in candidates if not args.simulator_id or d['udid'] == args.simulator_id)
        state['simulator'] = {'udid': device['udid'], 'name': device['name']}
        save()
        require('iPhone' in device.get('deviceTypeIdentifier', ''), 'Release verification requires an iPhone simulator')
        udid = device['udid']
        if device['state'] != 'Booted':
            run('simulator-boot', ['xcrun', 'simctl', 'boot', udid])
        run('simulator-ready', ['xcrun', 'simctl', 'bootstatus', udid, '-b'])
        run('simulator-install', ['xcrun', 'simctl', 'install', udid, derived / 'Build/Products/Debug-iphonesimulator/VoiceStudio.app'])
        container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', udid, BUNDLE, 'data'], text=True).strip())
        pack = ROOT / 'local-models/OpenVoiceV2'
        manifest = json.loads((pack / 'manifest.json').read_text())
        for item in manifest['files']:
            data = (pack / item['path']).read_bytes()
            require(len(data) == item['bytes'] and hashlib.sha256(data).hexdigest() == item['sha256'], "Validation failed: len(data) == item['bytes'] and hashlib.sha256(data).hexdigest() == item['sha256']")
        fixture = container / 'Documents/UIOpenVoicePack'
        if fixture.exists():
            expected = {p.relative_to(pack): p.read_bytes() for p in pack.rglob('*') if p.is_file()}
            actual = {p.relative_to(fixture): p.read_bytes() for p in fixture.rglob('*') if p.is_file()}
            require(actual == expected, 'Existing simulator fixture differs; refusing overwrite')
        else:
            shutil.copytree(pack, fixture)
        run('app-and-ui-tests', xcode + ['test', '-configuration', 'Debug', '-destination', 'platform=iOS Simulator,id=' + udid + ',arch=arm64',
                                        '-resultBundlePath', out / 'Tests.xcresult', '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never', 'ARCHS=arm64', 'CODE_SIGNING_ALLOWED=NO'])
        summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(out / 'Tests.xcresult')]))
        (out / 'test-summary.json').write_text(json.dumps(summary, indent=2))
        require(summary['failedTests'] == 0 and summary['skippedTests'] == 0 and summary['passedTests'] >= 73, 'Require full baseline App/UI suite: at least 73 passed, zero failed/skipped')
        run('runtime-device', ['bash', 'experiments/m2b-qwen-ios/scripts/build_formal_ios_runtime.sh', 'device'])
        run('release-build', xcode + ['-sdk', 'iphoneos', '-configuration', 'Release', 'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'build'])
        run('release-export-compliance', ['python3', 'scripts/local-ios-verify.py',
                                          derived / 'Build/Products/Release-iphoneos/VoiceStudio.app',
                                          '--check-export-compliance-only', '--report', out / 'release-export-compliance.json'])
        ort = next((derived / 'SourcePackages/artifacts').glob('**/onnxruntime.xcframework/ios-arm64/onnxruntime.framework'))
        run('align-ort', ['python3', 'scripts/align-onnxruntime-framework-minimum-os.py', ort, '17.0'])
        archive = out / 'VoiceStudio.xcarchive'
        run('archive', xcode + ['archive', '-configuration', 'Release', '-destination', 'generic/platform=iOS', '-archivePath', archive,
                               'MARKETING_VERSION=' + args.version, 'CURRENT_PROJECT_VERSION=' + args.build_number,
                               'DEVELOPMENT_TEAM=' + TEAM,
                               'VOICE_TESTFLIGHT_PROFILE_SPECIFIER=' + PROFILE, 'CODE_SIGNING_ALLOWED=YES'])
        def verify(name, app):
            run(name, ['python3', 'scripts/local-ios-verify.py', app, '--version', args.version, '--build', args.build_number, '--report', out / (name + '.json')])
        verify('archive-preflight', archive / 'Products/Applications/VoiceStudio.app')
        options = plistlib.loads((ROOT / 'ios/VoiceStudio.xcodeproj/ExportOptions-TestFlight.plist').read_bytes())
        require(options['destination'] == 'export' and options['teamID'] == TEAM, "Validation failed: options['destination'] == 'export' and options['teamID'] == TEAM")
        require(options['provisioningProfiles'] == {BUNDLE: PROFILE}, "Validation failed: options['provisioningProfiles'] == {BUNDLE: PROFILE}")
        options['manageAppVersionAndBuildNumber'] = False
        options['signingCertificate'] = IDENTITY
        export_options = out / 'ExportOptions.plist'
        export_options.write_bytes(plistlib.dumps(options))
        run('export', ['xcodebuild', '-exportArchive', '-archivePath', archive, '-exportPath', out / 'export', '-exportOptionsPlist', export_options])
        ipas = list((out / 'export').glob('*.ipa'))
        require(len(ipas) == 1, 'Validation failed: len(ipas) == 1')
        ipa = ipas[0]
        run('unpack-ipa', ['ditto', '-x', '-k', ipa, out / 'ipa-audit'])
        apps = list((out / 'ipa-audit/Payload').glob('*.app'))
        require(len(apps) == 1, 'Validation failed: len(apps) == 1')
        verify('ipa-preflight', apps[0])
        state['ipa_sha256'] = hashlib.sha256(ipa.read_bytes()).hexdigest()
        state['status'] = 'PASS_LOCAL_NO_UPLOAD'
        save()
        if args.upload:
            if args.upload_mode == 'xcode-account':
                # Xcode uses the account already configured in Xcode > Settings > Accounts.
                # Keep the exact build from the archive and never request provisioning changes.
                upload_options = dict(options)
                upload_options['method'] = 'app-store-connect'
                upload_options['destination'] = 'upload'
                upload_options['manageAppVersionAndBuildNumber'] = False
                upload_export_options = out / 'ExportOptions-Upload.plist'
                upload_export_options.write_bytes(plistlib.dumps(upload_options))
                run('upload', ['xcodebuild', '-exportArchive', '-archivePath', archive,
                               '-exportPath', out / 'upload-export',
                               '-exportOptionsPlist', upload_export_options])
                state['upload_result'] = 'UPLOAD_SUCCEEDED'
                state['apple_processing'] = 'PENDING_ASC_CONFIRMATION'
                state['status'] = 'UPLOAD_SUCCEEDED_PROCESSING_UNVERIFIED'
                save()
            else:
                # API-key upload remains available for unattended runs.
                with tempfile.TemporaryDirectory(prefix='voicestudio-upload-') as key_dir:
                    private_keys = Path(key_dir) / 'private_keys'
                    private_keys.mkdir(mode=0o700)
                    key_id = os.environ['API_KEY_ID']
                    require(re.fullmatch(r'[A-Za-z0-9]+', key_id), 'Invalid API key ID')
                    key = private_keys / ('AuthKey_' + key_id + '.p8')
                    with key.open('xb') as stream:
                        os.chmod(key, 0o600)
                        stream.write(base64.b64decode(os.environ['API_PRIVATE_KEY_BASE64'], validate=True))
                    run('upload', ['xcrun', 'altool', '--upload-app', '--type', 'ios', '--file', ipa,
                                   '--apiKey', key_id, '--apiIssuer', os.environ['API_ISSUER_ID']], cwd=key_dir)
                state['upload_result'] = 'UPLOAD_SUCCEEDED'
                state['status'] = 'UPLOADED_PROCESSING_UNVERIFIED'
                save()
                env = dict(os.environ, RUNNER_TEMP=str(out))
                run('apple-processing', ['python3', 'scripts/verify-appstore-build-ingestion.py', '--key-id', os.environ['API_KEY_ID'],
                                         '--issuer-id', os.environ['API_ISSUER_ID'], '--bundle-id', BUNDLE,
                                         '--version', args.version, '--build-number', args.build_number], env=env)
                state['apple_processing'] = 'VALID'
                state['status'] = 'PASS_APPLE_VALID'
            state['uploaded'] = True
            save()
        save()
        return 0
    except Exception as error:
        state['status'] = 'BLOCKED'
        state['error'] = str(error)
        save()
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
