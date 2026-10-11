#!/bin/bash
set -euo pipefail
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: verify-save-sync-signing.sh MeloNX.app [target-device-udid]" >&2
    exit 2
fi
python3 - "$@" <<'PY'
from pathlib import Path
import datetime, fnmatch, json, plistlib, subprocess, sys

app = Path(sys.argv[1]).resolve()
device = sys.argv[2] if len(sys.argv) > 2 else None
team, bundle, container = 'KWP42AEP6Q', 'com.hick.MeloNX', 'iCloud.com.hick.MeloNX'
checks = {}

def invoke(arguments):
    result = subprocess.run(arguments, capture_output=True)
    if result.returncode:
        raise RuntimeError('Signing or provisioning verification failed')
    return result

def entitlements(target):
    result = invoke(['codesign', '-d', '--entitlements', ':-', str(target)])
    for output in (result.stdout, result.stderr):
        start = output.find(b'<?xml')
        end = output.find(b'</plist>', start)
        if start >= 0 and end >= start:
            return plistlib.loads(output[start:end + len(b'</plist>')])
    raise RuntimeError('Code signature entitlements unavailable')

def profile(target):
    data = invoke(['security', 'cms', '-D', '-i', str(target / 'embedded.mobileprovision')]).stdout
    return plistlib.loads(data)

def cloud_documents_allowed(requested, permitted):
    if requested != ['CloudDocuments']:
        return False
    patterns = [permitted] if isinstance(permitted, str) else permitted
    return isinstance(patterns, list) and any(isinstance(value, str) and fnmatch.fnmatchcase('CloudDocuments', value) for value in patterns)

def inspect(target, expected_bundle, host):
    info = plistlib.loads((target / 'Info.plist').read_bytes())
    actual, provisioning = entitlements(target), profile(target)
    allowed = provisioning.get('Entitlements', {})
    prefix = 'host' if host else 'helper'
    checks[prefix + '_bundle_matches'] = info.get('CFBundleIdentifier') == expected_bundle
    checks[prefix + '_team_matches'] = actual.get('com.apple.developer.team-identifier') == team and team in provisioning.get('TeamIdentifier', [])
    application = actual.get('application-identifier', '')
    checks[prefix + '_application_allowed'] = application == team + '.' + expected_bundle and fnmatch.fnmatchcase(application, allowed.get('application-identifier', ''))
    checks[prefix + '_debug_allowed'] = actual.get('get-task-allow') is True and allowed.get('get-task-allow') is True
    expiry = provisioning.get('ExpirationDate')
    checks[prefix + '_profile_current'] = isinstance(expiry, datetime.datetime) and expiry.replace(tzinfo=datetime.timezone.utc) > datetime.datetime.now(datetime.timezone.utc)
    if device:
        checks[prefix + '_device_allowed'] = device in provisioning.get('ProvisionedDevices', [])
    cloud_keys = ['com.apple.developer.icloud-container-identifiers', 'com.apple.developer.ubiquity-container-identifiers']
    if host:
        services = actual.get('com.apple.developer.icloud-services', [])
        checks['host_cloud_documents_only'] = cloud_documents_allowed(services, allowed.get('com.apple.developer.icloud-services'))
        for key in cloud_keys:
            requested = actual.get(key, [])
            permitted = allowed.get(key, [])
            checks[key] = requested == [container] and any(fnmatch.fnmatchcase(container, value) for value in permitted)
        memory = 'com.apple.developer.kernel.increased-memory-limit'
        checks['host_increased_memory_allowed'] = actual.get(memory) is True and allowed.get(memory) is True
        public = info.get('NSUbiquitousContainers', {}).get(container, {})
        checks['host_document_container_configured'] = public.get('NSUbiquitousContainerName') == 'MeloNX' and public.get('NSUbiquitousContainerSupportedFolderLevels') == 'Any' and public.get('NSUbiquitousContainerIsDocumentScopePublic') is True
    else:
        checks['helper_has_no_cloud_entitlements'] = not actual.get('com.apple.developer.icloud-services') and all(not actual.get(key) for key in cloud_keys)

try:
    invoke(['codesign', '--verify', '--deep', '--strict', str(app)])
    checks['deep_strict_signature'] = True
    inspect(app, bundle, True)
    helpers = list((app / 'PlugIns').glob('*.appex'))
    checks['one_owned_helper'] = len(helpers) == 1
    if len(helpers) == 1:
        inspect(helpers[0], bundle + '.JITHelper', False)
    passed = bool(checks) and all(checks.values())
    print(json.dumps({'passed': passed, 'checks': checks}, sort_keys=True))
    sys.exit(0 if passed else 1)
except Exception:
    # Do not print the raw provisioning profile, certificate/account metadata,
    # codesign diagnostics or device identifiers into the verification proof.
    print(json.dumps({'passed': False, 'checks': checks, 'error': 'signing_verification_failed'}, sort_keys=True))
    sys.exit(1)
PY
