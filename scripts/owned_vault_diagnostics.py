"""Read-only, bounded failure observations for newly owned vault fixtures only.

This module never unlocks/unmounts an image, changes settings, or retries a
failed mutation. Reader observations are after failure and do not prove cause.
"""
import hashlib
import json
import os
import pathlib
import plistlib
import re
import selectors
import stat
import subprocess
import time
import uuid


def command(argv, *, timeout=5, limit=1024 * 1024):
    started = time.monotonic()
    child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, close_fds=True)
    output = [bytearray(), bytearray()]
    clipped = expired = False
    try:
        with selectors.DefaultSelector() as selector:
            for index, pipe in enumerate([child.stdout, child.stderr]):
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ, index)
            while selector.get_map():
                remaining = timeout - (time.monotonic() - started)
                if remaining <= 0:
                    expired = True
                    break
                for key, _ in selector.select(min(.05, remaining)):
                    data = os.read(key.fileobj.fileno(), min(65536, limit - sum(map(len, output)) + 1))
                    if not data:
                        selector.unregister(key.fileobj)
                    elif len(data) > limit - sum(map(len, output)):
                        clipped = True
                        break
                    else:
                        output[key.data].extend(data)
                if clipped:
                    break
        if clipped or expired:
            child.kill()  # Only this owned read-only diagnostic helper.
        try:
            child.wait(timeout=max(.05, timeout - (time.monotonic() - started)))
        except subprocess.TimeoutExpired:
            expired = True
            child.kill()
            child.wait()
        return dict(status=child.returncode, timedOut=expired, clipped=clipped,
                    seconds=time.monotonic() - started, stdout=bytes(output[0]), stderr=bytes(output[1]))
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        child.stdout.close()
        child.stderr.close()


def summary(result):
    return {**{key: result[key] for key in ['status', 'timedOut', 'clipped', 'seconds']},
            **{name + suffix: value for name in ['stdout', 'stderr']
               for suffix, value in [('Bytes', len(result[name])),
                                     ('SHA256', hashlib.sha256(result[name]).hexdigest())]}}


def parse_readers(data, mount, device):
    """Accept only descriptors on the exact owned device and mount prefix."""
    records, process, descriptor = [], {}, None
    def finish():
        if descriptor is None:
            return
        path = descriptor.get('n', '')
        aliases = [str(mount)]
        if str(mount).startswith('/private/var/'):
            aliases.append(str(mount)[8:])
        relative = next((path[len(prefix):] for prefix in aliases
                         if path == prefix or path.startswith(prefix + '/')), None)
        try:
            same = int(descriptor.get('D', ''), 16) == device
        except ValueError:
            same = False
        if same and relative is not None and '..' not in pathlib.PurePosixPath(relative).parts and process.get('p', '').isdigit() and len(records) < 256:
            records.append(dict(pid=int(process['p']), command=process.get('c', '')[:256],
                                descriptor=descriptor.get('f', '')[:32], type=descriptor.get('t', '')[:32],
                                inode=descriptor.get('i', '')[:32], path='<owned-mount>' + relative))
    for field in data.decode('utf-8', errors='replace').split('\0'):
        field = field.lstrip('\n')
        if not field:
            continue
        tag, value = field[0], field[1:]
        if tag == 'p':
            finish()
            process, descriptor = {'p': value}, None
        elif tag == 'c':
            process['c'] = value
        elif tag == 'f':
            finish()
            descriptor = {'f': value}
        elif tag in ['n', 'D', 't', 'i'] and descriptor is not None:
            descriptor[tag] = value
    finish()
    return records


class OwnedVaultDiagnostics:
    packages = frozenset(['Create.oswindvault', 'Unlock.oswindvault', 'Busy.oswindvault'])

    @classmethod
    def create(cls, root, secret, binary_sha256):
        if not re.fullmatch('[0-9a-f]{64}', binary_sha256) or not secret:
            raise ValueError('Invalid owned diagnostic binary or credential context')
        root = pathlib.Path(root).resolve()
        root.mkdir(mode=0o700, exist_ok=False)
        value = cls.__new__(cls)
        value.root, value.secret = root, secret
        value.binary_sha256 = binary_sha256
        value.identity = (root.stat().st_dev, root.stat().st_ino)
        marker = dict(format='OSwind owned terminal diagnostics v1', nonce=str(uuid.uuid4()), uid=os.getuid())
        fd = os.open(root / 'owned-fixture.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(marker, stream, sort_keys=True)
        value.marker = (root / 'owned-fixture.json').read_bytes()
        value.validate()
        return value

    def validate(self):
        info = self.root.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700 or (info.st_dev, info.st_ino) != self.identity:
            raise ValueError('Owned diagnostic root changed')
        if self.read_file(self.root / 'owned-fixture.json', 4096) != self.marker:
            raise ValueError('Owned diagnostic marker changed')

    @staticmethod
    def read_file(path, limit):
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > limit:
                raise ValueError('Owned diagnostic metadata differs')
            data = stream.read(limit + 1)
            if len(data) > limit:
                raise ValueError('Owned diagnostic metadata exceeds bound')
            return data

    def capture(self, package, *, run=command):
        self.validate()
        package = pathlib.Path(package)
        if package.parent != self.root or package.name not in self.packages or package.is_symlink():
            raise ValueError('Only the new terminal fixture package may be inspected')
        info = package.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError('Owned diagnostic package differs')
        result = dict(scope='After-failure observation only; reported readers are not proof of cause.', package=package.name)
        try:
            session = json.loads(self.read_file(package / 'session.json', 65536))
            leaf = session['mountLeaf']
            if str(uuid.UUID(leaf)) != leaf or session.get('phase') not in ['opening', 'unlocked', 'closing']:
                raise ValueError('Invalid owned session')
            parent = package / '.mounts'
            mount = parent / leaf
            if parent.is_symlink() or mount.is_symlink() or mount.resolve() != mount:
                raise ValueError('Owned mount path changed')
            stamp = mount.stat()
            if stamp.st_dev == info.st_dev or stamp.st_dev != session['rootDevice'] or stamp.st_ino != session['rootInode']:
                raise ValueError('Owned session is not its recorded mounted filesystem')
        except FileNotFoundError:
            result['mountObservation'] = 'No recorded mounted session; no reader query performed'
            return result
        result['phase'] = session['phase']
        inventory = run(['/usr/bin/hdiutil', 'info', '-plist'])
        result['inventoryQuery'] = summary(inventory)
        if inventory['status'] != 0 or inventory['clipped'] or inventory['timedOut']:
            result['mountObservation'] = 'Inventory unknown; no reader query performed'
            return result
        target = str(package / 'contents.sparsebundle')
        aliases = [target, target[8:]] if target.startswith('/private/var/') else [target]
        owned = [image for image in plistlib.loads(inventory['stdout']).get('images', [])
                 if image.get('image-path') in aliases]
        mounts = [str(mount), str(mount)[8:]] if str(mount).startswith('/private/var/') else [str(mount)]
        if len(owned) != 1 or not any(entity.get('mount-point') in mounts and entity.get('dev-entry') == session.get('device') for entity in owned[0].get('system-entities', [])):
            result['mountObservation'] = 'Recorded mount not confirmed by owned inventory; no reader query performed'
            return result
        self.validate()
        readers = run(['/usr/sbin/lsof', '-nP', '-F0pcfntDi', '+f', '--', str(mount)])
        self.validate()
        after = mount.stat()
        if (stamp.st_dev, stamp.st_ino) != (after.st_dev, after.st_ino):
            raise ValueError('Owned mounted identity changed during reader observation')
        result['readerQuery'] = summary(readers)
        result['readers'] = [] if readers['clipped'] or readers['timedOut'] else parse_readers(readers['stdout'], mount, stamp.st_dev)
        result['readerLimit'] = 256
        result['mountObservation'] = 'Owned mounted filesystem observed; empty output is not proof that no readers exist'
        if self.secret in json.dumps(result).encode():
            raise ValueError('Credential appeared in diagnostic metadata')
        return result

    def save_failure(self, package, action, code, *, stdout=b'', stderr=b'', run=command):
        self.validate()
        if action not in ['create', 'unlock', 'lock', 'status'] or self.secret in stdout + stderr:
            raise ValueError('Invalid owned diagnostic outcome')
        record = dict(format='OSwind owned terminal failure v1', action=action, exitCode=code,
                      binarySHA256=self.binary_sha256,
                      output={name: dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
                              for name, data in [('stdout', stdout), ('stderr', stderr)]})
        # These are the CLI's reported native outcomes, not an interpretation of
        # the CLI exit code or proof of the cause of a native nonzero status.
        record['reportedNativeOutcomes'] = [dict(tool=tool.decode(), termination=reason.decode(), status=int(status))
            for tool, reason, status in re.findall(rb'\b(hdiutil|diskutil|umount) (exit|signal|termination status) (-?\d{1,10})\b', stdout + b'\n' + stderr)[:16]]
        try:
            record['observation'] = self.capture(package, run=run)
        except Exception as error:
            record['diagnosticRefused'] = type(error).__name__
        encoded = json.dumps(record, indent=2).encode()
        if self.secret in encoded:
            raise ValueError('Credential appeared in diagnostic record')
        self.validate()
        name = 'failure-' + str(uuid.uuid4()) + '.json'
        fd = os.open(self.root / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(encoded + b'\n')
        return self.root / name
