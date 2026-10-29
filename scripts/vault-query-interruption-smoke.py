#!/usr/bin/env python3
"""Interrupt only owned CLI hdiutil inventory children and retain kernel exit status.

macOS, explicit fresh private fixture root, no user library/terminal/Keychain.
SIGSTOP permits a second PID/parent/command check before SIGINT or SIGTERM.
EVFILT_PROC NOTE_EXITSTATUS distinguishes uncaught signal 2 from normal exit 2.
All predeclared trials, including missed or handled signals, remain in the report.
"""
import argparse
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import plistlib
import secrets
import select
import signal
import subprocess
import sys
import time

EXITSTATUS = 0x04000000  # Darwin sys/event.h NOTE_EXITSTATUS.


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def watch(pid):
    queue = select.kqueue()
    try:
        queue.control([select.kevent(pid, filter=select.KQ_FILTER_PROC,
                                    flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_ONESHOT,
                                    fflags=select.KQ_NOTE_EXIT | EXITSTATUS)], 0, 0)
        return queue
    except BaseException:
        queue.close()
        raise


def outcome(event):
    assert event.filter == select.KQ_FILTER_PROC and event.fflags & select.KQ_NOTE_EXIT
    assert event.fflags & EXITSTATUS, 'Kernel did not supply exit status'
    assert not event.flags & select.KQ_EV_ERROR
    status = int(event.data)
    if os.WIFSIGNALED(status):
        return dict(termination='signal', status=os.WTERMSIG(status), waitStatus=status)
    assert os.WIFEXITED(status), ('Unknown kernel termination', status)
    return dict(termination='exit', status=os.WEXITSTATUS(status), waitStatus=status)


def calibrate():
    records = []
    for mode in ['exit2', 'SIGINT']:
        command = ['/usr/bin/python3', '-c', 'import sys;sys.stdin.buffer.read(1);raise SystemExit(2)'] if mode == 'exit2' else ['/bin/sleep', '10']
        process = subprocess.Popen(command, stdin=subprocess.PIPE if mode == 'exit2' else subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        queue = watch(process.pid)
        try:
            if mode == 'SIGINT':
                process.send_signal(signal.SIGINT)
            else:
                process.stdin.write(b'x')
                process.stdin.close()
                process.stdin = None
            events = queue.control([], 1, 5)
            stdout, stderr = process.communicate(timeout=5)
            assert not stdout and not stderr and len(events) == 1
            value = outcome(events[0])
            assert value['status'] == 2 and value['termination'] == ('exit' if mode == 'exit2' else 'signal')
            assert process.returncode == (2 if mode == 'exit2' else -2)
            records.append(dict(mode=mode, kernel=value, childReturncode=process.returncode))
        finally:
            queue.close()
            if process.poll() is None:
                process.kill()
                process.wait()
    return records


class BSDInfo(ctypes.Structure):
    # Public macOS sys/proc_info.h struct proc_bsdinfo (136 bytes).
    _fields_ = [(name, ctypes.c_uint32) for name in
                ['flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid', 'svuid', 'svgid', 'reserved']]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ['nfiles', 'pgid', 'pjobc', 'tty', 'ttygroup']]
    _fields_ += [('nice', ctypes.c_int32), ('startSeconds', ctypes.c_uint64), ('startMicros', ctypes.c_uint64)]


def native_process_api():
    lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    lib.proc_pidinfo.restype = ctypes.c_int
    lib.proc_listchildpids.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
    lib.proc_listchildpids.restype = ctypes.c_int
    lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    lib.proc_pidpath.restype = ctypes.c_int
    assert ctypes.sizeof(BSDInfo) == 136
    own = process_info(lib, os.getpid())
    assert own and (own.pid, own.ppid, own.uid) == (os.getpid(), os.getppid(), os.getuid()), 'Native process ABI calibration failed'
    return lib


def process_info(lib, pid):
    value = BSDInfo()
    count = lib.proc_pidinfo(pid, 3, 0, ctypes.byref(value), ctypes.sizeof(value))
    return value if count == ctypes.sizeof(value) and value.pid == pid else None


def inventory_child(pid, lib, seen):
    # Zeroed bounded PID buffer. Only direct children of this exact owned CLI
    # are inspected; no argv/environment or normal application content is read.
    children = (ctypes.c_int * 64)()
    count = lib.proc_listchildpids(pid, children, ctypes.sizeof(children))
    if count <= 0:
        return None
    for child in children:
        if child <= 0 or child in seen:
            continue
        info = process_info(lib, child)
        if not info or info.ppid != pid or info.uid != os.getuid() or info.comm != b'hdiutil':
            continue
        path = ctypes.create_string_buffer(4096)
        if lib.proc_pidpath(child, path, len(path)) > 0 and path.value == b'/usr/bin/hdiutil':
            return child
    return None


def inspect_child(child, parent):
    p = subprocess.run(['/bin/ps', '-ww', '-p', str(child), '-o', 'pid=,ppid=,state=,command='], capture_output=True, text=True, timeout=3)
    fields = p.stdout.strip().split(None, 3)
    if len(fields) == 4 and fields[:2] == [str(child), str(parent)] and fields[3] == '/usr/bin/hdiutil info -plist':
        return fields[2]
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--baseline-sha256')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Requires macOS kqueue and encrypted APFS tools')
    if bool(args.baseline) != bool(args.baseline_sha256):
        parser.error('Supply both baseline path and pinned SHA256')
    binary = args.binary.resolve(strict=True)
    root = args.root.resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    binaries = dict(candidate=binary)
    if args.baseline:
        binaries['baseline'] = args.baseline.resolve(strict=True)
        assert sha(binaries['baseline']) == args.baseline_sha256
    hashes = {name: sha(path) for name, path in binaries.items()}
    trials = [dict(binary=name, signal='SIGINT', targets=1, repetition=i) for name in binaries for i in range(4)]
    trials += [dict(binary='candidate', signal=mode, targets=targets, repetition=i) for mode, targets in [('SIGINT', 2), ('SIGTERM', 1)] for i in range(3)]
    report = dict(format='OSwind owned native inventory child interruption v1', state='planned', binarySHA256=hashes,
                  scriptSHA256=sha(Path(__file__)), plan=trials, trials=[],
                  scope='Only direct owned CLI hdiutil info -plist children; private synthetic encrypted APFS. No user terminal, library, credentials, Keychain, permissions, forced detach or power changes. Direct child signals are not parent Ctrl-C.',
                  passphrasePersisted=False)

    def save():
        (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')

    save()
    report['calibration'] = calibrate()
    lib = native_process_api()
    report['observer'] = 'Bounded proc_listchildpids/proc_pidinfo/proc_pidpath; calibrated 136-byte BSD info, own UID, direct parent and exact executable before STOP; complete ps -ww command and stopped state before test signal; no process environment reads'
    package = root / 'Fixture.oswindvault'
    secret = secrets.token_urlsafe(32).encode()

    def run(*command, password=None):
        assert sha(binary) == hashes['candidate']
        p = subprocess.run([str(binary), *map(str, command)], input=password + b'\0' if password else b'', capture_output=True, timeout=180)
        assert secret not in p.stdout + p.stderr
        assert p.returncode == 0, (p.returncode, p.stderr.decode(errors='replace'))
        return p.stdout

    def detached():
        info = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist']))
        return not any(Path(v.get('image-path', '/missing')).resolve() == (package / 'contents.sparsebundle').resolve() for v in info.get('images', []))

    try:
        run('vault', 'create', package, '--capacity-gb', '1', '--passphrase-stdin', password=secret)
        run('vault', 'unlock', package, '--passphrase-stdin', password=secret)
        identifier = run('--vault', package, 'note', 'Owned query interruption marker').decode().strip()
        run('vault', 'lock', package)
        assert detached()
        report['state'] = 'running'
        save()
        for index, plan in enumerate(trials):
            selected = binaries[plan['binary']]
            assert sha(selected) == hashes[plan['binary']]
            p = subprocess.Popen([str(selected), 'vault', 'status', str(package)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            targets = []
            seen = set()
            watched = []
            stopped = None
            start = time.monotonic()
            try:
                while p.poll() is None and time.monotonic() - start < 20:
                    for item in watched:
                        if 'kernel' not in item['record']:
                            events = item['queue'].control([], 1, 0)
                            if events:
                                item['record']['kernel'] = outcome(events[0])
                    if len(targets) < plan['targets']:
                        child = inventory_child(p.pid, lib, seen)
                        if child:
                            seen.add(child)
                            before = process_info(lib, child)
                            if not before or before.ppid != p.pid:
                                continue
                            try:
                                os.kill(child, signal.SIGSTOP)
                                stopped = child
                            except ProcessLookupError:
                                continue
                            stop_deadline = time.monotonic() + 0.25
                            after = process_info(lib, child)
                            while after and after.status != 4 and time.monotonic() < stop_deadline:
                                time.sleep(.0001)
                                after = process_info(lib, child)
                            state = inspect_child(child, p.pid)
                            if (state and state.startswith('T') and after and after.status == 4 and
                                    (after.ppid, after.uid, after.startSeconds, after.startMicros) ==
                                    (p.pid, os.getuid(), before.startSeconds, before.startMicros)):
                                queue = watch(child)
                                record = dict(pid=child, parent=p.pid, command='hdiutil info -plist', signalSent=True,
                                              stoppedIdentityConfirmed=True)
                                watched.append(dict(queue=queue, record=record))
                                os.kill(child, getattr(signal, plan['signal']))
                                targets.append(record)
                            try:
                                os.kill(child, signal.SIGCONT)
                            except ProcessLookupError:
                                pass
                            stopped = None
                    time.sleep(.0002)
                stdout, stderr = p.communicate(timeout=5)
                assert len(stdout) + len(stderr) <= 1024 * 1024 and secret not in stdout + stderr
                for item in watched:
                    if 'kernel' not in item['record']:
                        events = item['queue'].control([], 1, 2 if item['record']['signalSent'] else 0)
                        if events:
                            item['record']['kernel'] = outcome(events[0])
                (root / f'trial-{index:02d}.stdout').write_bytes(stdout)
                (root / f'trial-{index:02d}.stderr').write_bytes(stderr)
                valid = [t for t in targets if t.get('kernel', {}).get('termination') == 'signal' and t['kernel']['status'] == getattr(signal, plan['signal'])]
                assert all('kernel' in t for t in targets), 'Signalled helper exit status was not observed'
                expected = None
                if len(valid) == plan['targets']:
                    expected = 0 if plan['binary'] == 'candidate' and plan['signal'] == 'SIGINT' and plan['targets'] == 1 else 1
                    assert p.returncode == expected, (plan, p.returncode, stderr.decode(errors='replace'))
                    if expected == 0:
                        status = json.loads(stdout)
                        assert status['state'] == 'locked' and not status['imageAttached'] and not status['volumeMounted']
                    else:
                        assert not stdout and f"hdiutil signal {getattr(signal, plan['signal'])}".encode() in stderr
                assert detached()
                row = dict(plan=plan, cliExit=p.returncode, targets=targets, kernelConfirmedTargets=len(valid), expectedExit=expected,
                           stdoutSHA256=hashlib.sha256(stdout).hexdigest(), stderrSHA256=hashlib.sha256(stderr).hexdigest(), seconds=time.monotonic()-start)
                report['trials'].append(row)
                save()
            finally:
                if stopped:
                    try:
                        os.kill(stopped, signal.SIGCONT)
                    except ProcessLookupError:
                        pass
                for item in watched:
                    item['queue'].close()
                if p.poll() is None:
                    child = inventory_child(p.pid, lib, set())
                    if child:
                        try:
                            os.kill(child, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                    try:
                        p.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        p.terminate()
                        p.communicate(timeout=5)
            assert sha(selected) == hashes[plan['binary']]
        required = [('candidate', 'SIGINT', 1), ('candidate', 'SIGINT', 2), ('candidate', 'SIGTERM', 1)]
        if 'baseline' in binaries:
            required.append(('baseline', 'SIGINT', 1))
        coverage = {str(key): sum(t['expectedExit'] is not None and (t['plan']['binary'], t['plan']['signal'], t['plan']['targets']) == key for t in report['trials']) for key in required}
        report['confirmedCoverage'] = coverage
        assert all(coverage.values()), ('No confirmed native trial for a predeclared contract', coverage)
        run('vault', 'unlock', package, '--passphrase-stdin', password=secret)
        assert json.loads(run('--vault', package, 'get', identifier))['text'] == 'Owned query interruption marker'
        run('vault', 'lock', package)
        assert detached()
        report.update(state='completed', historyPreserved=True, independentlyDetached=True)
        save()
        print(json.dumps(dict(state=report['state'], trials=len(report['trials']), confirmedCoverage=coverage)), flush=True)
    except BaseException as error:
        report.update(state='failed', errorType=type(error).__name__)
        try:
            run('vault', 'lock', package)
            report['normalRecoveryDetached'] = detached()
        except BaseException as recovery:
            report['normalRecoveryErrorType'] = type(recovery).__name__
        save()
        raise


if __name__ == '__main__':
    main()
