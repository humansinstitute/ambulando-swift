#!/usr/bin/env python3
"""Build and launch the isolated sample app; fail if its readiness marker is absent."""
import argparse
import os
from pathlib import Path
import plistlib
import platform
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('platform', choices=['mac', 'iphone'])
parser.add_argument('--reset', action='store_true', help='Reset only this test app’s sample data and preferences')
parser.add_argument('--timeout', type=float, default=45)
parser.add_argument('--missing-fixture', action='store_true', help='Exercise fail-closed startup (must time out)')
args = parser.parse_args()
os.chdir(ROOT)
evidence = ROOT / 'tmp/docs/handoffs/test-apps'
evidence.mkdir(parents=True, exist_ok=True)

def run(*command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)

def output(*command):
    return subprocess.check_output(command, text=True).strip()

mac = args.platform == 'mac'
scheme = 'AmbulandoMacTest' if mac else 'AmbulandoTest'
bundle = 'studio.otherstuff.ambulando.' + ('mac.test' if mac else 'native.test')
derived = ROOT / ('build/test-' + ('mac' if mac else 'ios'))
with (evidence / (args.platform + '-build.log')).open('w') as log:
    run('xcodebuild', '-project', 'Ambulando.xcodeproj', '-scheme', scheme,
        '-destination', 'platform=macOS' if mac else 'generic/platform=iOS Simulator',
        '-derivedDataPath', str(derived), '-skipPackagePluginValidation', 'ARCHS=' + platform.machine(), 'build', stdout=log, stderr=subprocess.STDOUT)
app = derived / 'Build/Products' / ('Test' if mac else 'Test-iphonesimulator') / 'Ambulando Test.app'
info = plistlib.loads((app / ('Contents/Info.plist' if mac else 'Info.plist')).read_bytes())
if info['CFBundleIdentifier'] != bundle:
    sys.exit('Refusing to launch an app with an unexpected bundle identifier')
flags = ['-AmbulandoFixtureReset'] if args.reset else []
if args.missing_fixture:
    flags += ['-AmbulandoTestMissingFixture']
if mac:
    # Terminate only the dedicated test bundle, never the normal app.
    try:
        subprocess.run(['osascript', '-e', f'tell application id "{bundle}" to quit'],
                       timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        sys.exit('FAILED: Ambulando Test did not quit within 5s; refusing a duplicate launch')
    container = Path.home() / 'Library/Containers' / bundle / 'Data'
else:
    import json
    devices = json.loads(output('xcrun', 'simctl', 'list', 'devices', 'available', '--json'))['devices']
    phone = next((d for group in devices.values() for d in group if d['name'] == 'Ambulando Test iPhone'), None)
    if not phone:
        udid = output('xcrun', 'simctl', 'create', 'Ambulando Test iPhone', 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro')
    else:
        udid = phone['udid']
    subprocess.run(['xcrun', 'simctl', 'boot', udid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run('xcrun', 'simctl', 'bootstatus', udid, '-b')
    run('open', '-a', 'Simulator')
    run('xcrun', 'simctl', 'install', udid, str(app))
    subprocess.run(['xcrun', 'simctl', 'terminate', udid, bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    container = Path(output('xcrun', 'simctl', 'get_app_container', udid, bundle, 'data'))
marker = container / 'Library/Caches/AmbulandoTest' / bundle / 'AmbulandoFixture/test-readiness.txt'
marker.unlink(missing_ok=True)
if args.reset:
    # Standard preferences are scoped by the separate bundle, including @AppStorage.
    (container / 'Library/Preferences' / (bundle + '.plist')).unlink(missing_ok=True)
if mac:
    run('open', '-n', str(app), '--args', *flags)
else:
    run('xcrun', 'simctl', 'launch', udid, bundle, *flags)
print(f'Build {info["CFBundleVersion"]}: {app}\nBundle: {bundle}\nData: {container}', flush=True)
deadline = time.monotonic() + args.timeout
while time.monotonic() < deadline:
    if marker.exists():
        print(marker.read_text())
        sys.exit(0)
    time.sleep(0.25)
sys.exit(f'FAILED: fixture readiness timeout after {args.timeout:g}s; production fallback is forbidden')
