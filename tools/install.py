#!/usr/bin/env python3
"""Install only RevivePlex on an already jailbroken, supported Apple TV."""
import argparse
import hashlib
import io
import pathlib
import plistlib
import re
import subprocess
import tarfile
import uuid

DEST = '/Applications/AppleTV.app/Appliances/RevivePlex.frappliance'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('host', help='root@APPLE_TV_IP, or root@127.0.0.1 for USB forwarding')
p.add_argument('--port', type=int, default=22)
p.add_argument('--bundle', type=pathlib.Path, default=pathlib.Path('build/native/RevivePlex.frappliance'))
p.add_argument('--legacy-ssh', action='store_true', help='Allow the old device ssh-rsa host-key algorithm')
p.add_argument('--host-key-alias', help='Use the device hostname for known_hosts when forwarding USB')
p.add_argument('--check', action='store_true', help='Check prerequisites without installing or restarting')
a = p.parse_args()
if not re.fullmatch(r'root@[A-Za-z0-9.-]+', a.host) or not 1 <= a.port <= 65535:
    p.error('Use root@hostname or root@IPv4 and a valid port.')
ssh = ['ssh', '-p', str(a.port), '-o', 'ConnectTimeout=15']
if a.legacy_ssh:
    ssh += ['-o', 'HostKeyAlgorithms=+ssh-rsa']
if a.host_key_alias:
    if not re.fullmatch(r'[A-Za-z0-9.-]+', a.host_key_alias): p.error('Invalid host-key alias')
    ssh += ['-o', 'HostKeyAlias=' + a.host_key_alias]
ssh += [a.host]
def remote(command, data=None):
    return subprocess.run(ssh + [command], input=data, stdout=subprocess.PIPE, check=True).stdout
model = remote('sysctl -n hw.machine').decode().strip()
firmware = plistlib.loads(remote('cat /System/Library/CoreServices/SystemVersion.plist'))
loader = remote("dpkg-query -W -f='${Status}' beigelist").decode().strip()
if model != 'AppleTV3,2' or firmware.get('ProductBuildVersion') != '12H1006' or loader != 'install ok installed':
    raise SystemExit('Requires AppleTV3,2 / 12H1006 with beigelist already installed. Nothing changed.')
print('Supported hardware, firmware and appliance loader detected.')
if a.check:
    raise SystemExit(0)
bundle = a.bundle.resolve()
meta = plistlib.loads((bundle / 'Info.plist').read_bytes())
if meta.get('CFBundleIdentifier') != 'org.revivetv.frontrow.appliance.reviveplex':
    raise SystemExit('Not a RevivePlex bundle.')
exe = bundle / 'RevivePlex'
expected = hashlib.sha256(exe.read_bytes()).hexdigest()
staging = '/tmp/RevivePlex-install-' + uuid.uuid4().hex
archive = io.BytesIO()
with tarfile.open(fileobj=archive, mode='w') as tar:
    for name in ['Info.plist', 'RevivePlex']:
        if (bundle / name).is_symlink():
            raise SystemExit('Bundle symlinks are not accepted.')
        tar.add(bundle / name, arcname=name)
remote('mkdir -m 700 ' + staging)
try:
    remote('tar -xf - -C ' + staging, archive.getvalue())
    actual = hashlib.sha256(remote('cat ' + staging + '/RevivePlex')).hexdigest()
    if actual != expected:
        raise SystemExit('Transfer checksum mismatch. Existing installation unchanged.')
    backup = '/var/mobile/Library/Caches/RevivePlex-backups/' + uuid.uuid4().hex
    remote('set -e\nmkdir -p ' + backup + '\n' +
           'if [ -d ' + DEST + ' ]; then cp -Rp ' + DEST + ' ' + backup + '/RevivePlex.frappliance; fi\n' +
           'chmod 755 ' + staging + '/RevivePlex\nchmod 644 ' + staging + '/Info.plist\nchown -R root:wheel ' + staging + '\n' +
           'mkdir -p ' + DEST + '\ncp ' + staging + '/Info.plist ' + DEST + '/Info.plist\n' +
           'cp ' + staging + '/RevivePlex ' + DEST + '/RevivePlex.new\n' +
           'chmod 755 ' + DEST + '/RevivePlex.new\nmv -f ' + DEST + '/RevivePlex.new ' + DEST + '/RevivePlex\n')
    print('Installed and verified. Previous bundle backup: ' + backup)
    print('Restarting the Apple TV interface. Plex account/preferences are preserved.')
    remote('killall AppleTV')
finally:
    remote('rm -f ' + staging + '/Info.plist ' + staging + '/RevivePlex; rmdir ' + staging)
