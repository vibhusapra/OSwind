#!/usr/bin/env python3
"""Owned child/diagnostic fault contracts; no native capture, history or TCC."""
import contextlib
import errno
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from soak_process_owner import reap_all, reap_owned

ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('soak_controller',ROOT/'native-targeted-capture-soak.py')
controller=importlib.util.module_from_spec(spec);spec.loader.exec_module(controller)
REAL_POPEN=subprocess.Popen


@unittest.skipUnless(os.name=='posix','Mac/Unix owned-process contracts')
class OwnedProcessTests(unittest.TestCase):
    def child(self,ignore=False):
        code='import signal,time,sys\n'
        if ignore:code+='signal.signal(signal.SIGTERM,signal.SIG_IGN)\n'
        code+='print("ready",flush=True)\ntime.sleep(60)\n'
        child=REAL_POPEN([sys.executable,'-c',code],stdout=subprocess.PIPE,text=True)
        self.addCleanup(self.emergency,child)
        self.assertEqual(child.stdout.readline().strip(),'ready')
        child.stdout.close()
        return child

    def emergency(self,child):
        if child.poll() is None:child.kill()
        child.wait()

    def assert_reaped(self,child):
        self.assertIsNotNone(child.returncode)
        with self.assertRaises(ChildProcessError):os.waitpid(child.pid,os.WNOHANG)
        with self.assertRaises(ProcessLookupError):os.kill(child.pid,0)

    def test_stop_file_enospc_still_reaps_worker_and_fixture(self):
        worker=self.child();fixture=self.child()
        def denied():raise OSError(errno.ENOSPC,'injected disk full')
        result=reap_all(worker,fixture,denied,grace=.02,terminate_grace=.05)
        self.assert_reaped(worker);self.assert_reaped(fixture)
        self.assertTrue(all(r['reaped'] for r in result.values()))
        self.assertFalse(result['worker']['stopRequested'])
        self.assertEqual(result['worker']['errors'],[{'stage':'request-stop','type':'OSError'}])

    def test_ignored_termination_escalates_to_owned_kill_and_wait(self):
        child=self.child(ignore=True)
        result=reap_owned(child,lambda:None,grace=.02,terminate_grace=.02)
        self.assertTrue(result['stopRequested']);self.assertTrue(result['terminated']);self.assertTrue(result['killed'])
        self.assertEqual(result['exit'],-signal.SIGKILL);self.assert_reaped(child)

    def test_completed_child_is_reaped_without_stop_or_signal(self):
        child=REAL_POPEN([sys.executable,'-c','raise SystemExit(7)']);self.addCleanup(self.emergency,child)
        child.wait()
        with patch.object(child,'terminate',side_effect=AssertionError('Must not signal')),patch.object(child,'kill',side_effect=AssertionError('Must not signal')):
            result=reap_owned(child,lambda:self.fail('Must not request stop'))
        self.assertEqual(result['exit'],7);self.assertTrue(result['reaped']);self.assert_reaped(child)

    def test_interrupted_final_wait_still_joins_and_records_interrupt(self):
        child=self.child();real=child.wait;injected=False
        def wait(timeout=None):
            nonlocal injected
            if timeout is None and not injected:injected=True;raise KeyboardInterrupt()
            return real(timeout=timeout)
        with patch.object(child,'wait',side_effect=wait):result=reap_owned(child,terminate_grace=.05)
        self.assertTrue(result['reaped']);self.assertIn({'stage':'final-wait','type':'KeyboardInterrupt'},result['errors']);self.assert_reaped(child)

    def test_one_cleanup_exception_still_joins_both_children(self):
        worker=self.child();fixture=self.child();real=reap_owned
        def broken(child,*args,**kwargs):
            if child is worker:raise RuntimeError('injected owner fault')
            return real(child,*args,**kwargs)
        with patch('soak_process_owner.reap_owned',side_effect=broken):
            result=reap_all(worker,fixture,terminate_grace=.02)
        self.assertTrue(result['worker']['reaped']);self.assertTrue(result['worker']['killed'])
        self.assertTrue(result['fixture']['reaped']);self.assert_reaped(worker);self.assert_reaped(fixture)
        self.assertIn({'stage':'cleanup','type':'RuntimeError'},result['worker']['errors'])

    def test_graceful_stop_file_joins_without_termination(self):
        with tempfile.TemporaryDirectory(prefix='oswind-stop-contract-') as folder:
            marker=Path(folder)/'stop'
            code='import pathlib,time; p=pathlib.Path('+repr(str(marker))+')\nprint("ready",flush=True)\nwhile not p.exists():time.sleep(.001)\n'
            child=REAL_POPEN([sys.executable,'-c',code],stdout=subprocess.PIPE,text=True);self.addCleanup(self.emergency,child)
            self.assertEqual(child.stdout.readline().strip(),'ready');child.stdout.close()
            result=reap_owned(child,lambda:marker.write_text('stop'),grace=1,terminate_grace=.02)
            self.assertEqual(result['exit'],0);self.assertTrue(result['stopRequested'])
            self.assertFalse(result['terminated']);self.assertFalse(result['killed']);self.assert_reaped(child)

    def test_unrelated_sentinel_is_never_signaled(self):
        worker=self.child();sentinel=self.child()
        result=reap_owned(worker,terminate_grace=.02)
        self.assertTrue(result['reaped']);self.assertIsNone(sentinel.poll());self.assert_reaped(worker)


@unittest.skipUnless(os.name=='posix','Mac/Unix owned-process contracts')
class ControllerContracts(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='oswind-soak-contract-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.children=[];self.addCleanup(self.emergency)
        self.bundle=self.root/'OSwindPackageTests.xctest';path=self.bundle/'Contents/MacOS/OSwindPackageTests';path.parent.mkdir(parents=True);path.write_bytes(b'authored fake XCTest identity, never executed')
        files={str(p.relative_to(self.bundle)):hashlib.sha256(p.read_bytes()).hexdigest() for p in self.bundle.rglob('*') if p.is_file()}
        self.proof=self.root/'provenance.json';self.proof.write_text(json.dumps({'bundle':str(self.bundle),'files':files}))
        self.fixture=self.root/'fixture.py';self.fixture.write_text('#!'+sys.executable+'\n'+'''import json,os,pathlib,plistlib,sys,time
p=pathlib.Path(sys.argv[0]);info=plistlib.loads((p.parents[1]/'Info.plist').read_bytes())
pathlib.Path(sys.argv[1]).write_text(json.dumps({'pid':os.getpid(),'bundle':info['CFBundleIdentifier'],'executable':str(p),'stableSCObservations':3,'windowID':1}))
time.sleep(60)
''');self.fixture.chmod(0o700)
        self.out=self.root/'output';self.out.mkdir()
        self.argv=['--bundle',str(self.bundle),'--provenance',str(self.proof),'--fixture',str(self.fixture),'--seconds','5','--output-parent',str(self.out)]

    def emergency(self):
        for child in self.children:
            if child.poll() is None:child.kill()
            child.wait()

    def assert_joined(self):
        self.assertTrue(self.children)
        for child in self.children:
            self.assertIsNotNone(child.returncode)
            with self.assertRaises(ChildProcessError):os.waitpid(child.pid,os.WNOHANG)
        return next(self.out.iterdir())

    def native_run(self,command,**kwargs):
        if command[0] in ['codesign','ps']:return subprocess.CompletedProcess(command,0,stdout='',stderr='')
        self.fail('Unexpected native command '+repr(command))

    def launch(self,success=False):
        def popen(command,**kwargs):
            if command[0]=='xcrun':
                self.assertEqual(command[1:4],['xctest','-XCTest','OSwindCoreTests.NativeTargetedCaptureSoakTests/testOwnedPersistentTargetedCapture'])
                if success:
                    coverage=getattr(self,'worker_coverage',True)
                    code="import json,os,pathlib; p=pathlib.Path(os.environ['OSWIND_TEST_TARGETED_SOAK_CONFIGURATION']);r=p.parent;(r/'status.json').write_text(json.dumps({'coverageQualified':"+repr(coverage)+",'sourceCount':1,'pid':os.getpid()}));(r/'prerequisites.json').write_text(json.dumps({'ready':"+repr(coverage)+"}))"
                else:code='import time;time.sleep(60)'
                child=REAL_POPEN([sys.executable,'-c',code],**kwargs)
            else:child=REAL_POPEN(command,**kwargs)
            self.children.append(child);return child
        return popen

    @contextlib.contextmanager
    def environment(self,success=False):
        with patch.object(controller.subprocess,'Popen',side_effect=self.launch(success)),patch.object(controller.subprocess,'run',side_effect=self.native_run),patch.object(controller.subprocess,'check_output',return_value='authored host'),patch.object(controller,'STOP_GRACE_SECONDS',.02),patch.object(controller,'TERMINATE_GRACE_SECONDS',.05),contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):
            yield

    def test_heartbeat_stop_and_error_receipts_enospc_never_skip_cleanup(self):
        real_atomic=controller.atomic;real_write=Path.write_text
        def atomic(path,value):
            if path.name in ['controller-heartbeat.json','controller-error.json','fixture-exit.json']:raise OSError(errno.ENOSPC,'injected full disk')
            return real_atomic(path,value)
        def write(path,*args,**kwargs):
            if path.name=='stop-requested':raise OSError(errno.ENOSPC,'injected full disk')
            return real_write(path,*args,**kwargs)
        with self.environment(),patch.object(controller,'atomic',side_effect=atomic),patch.object(Path,'write_text',write):
            with self.assertRaises(OSError) as caught:controller.main(self.argv)
        self.assertEqual(caught.exception.errno,errno.ENOSPC)
        root=self.assert_joined();self.assertEqual(len(self.children),2);self.assertFalse((root/'controller-final.json').exists())

    def test_output_failure_immediately_after_fixture_launch_still_reaps(self):
        with self.environment(),patch('builtins.print',side_effect=BrokenPipeError('injected stdout failure')):
            with self.assertRaises(BrokenPipeError):controller.main(self.argv)
        self.assert_joined();self.assertEqual(len(self.children),1)

    def test_process_handle_write_failure_preserves_primary_and_joins_both(self):
        real=controller.atomic
        def atomic(path,value):
            if path.name=='process-handle.json':raise OSError(errno.EIO,'injected handle receipt failure')
            return real(path,value)
        with self.environment(),patch.object(controller,'atomic',side_effect=atomic):
            with self.assertRaises(OSError) as caught:controller.main(self.argv)
        self.assertEqual(caught.exception.errno,errno.EIO);root=self.assert_joined()
        self.assertEqual(json.loads((root/'controller-error.json').read_text())['type'],'OSError')
        self.assertFalse((root/'controller-final.json').exists())

    def test_worker_launch_failure_still_reaps_fixture(self):
        launch=self.launch()
        def popen(command,**kwargs):
            if command[0]=='xcrun':raise OSError(errno.EAGAIN,'injected launch failure')
            return launch(command,**kwargs)
        with self.environment(),patch.object(controller.subprocess,'Popen',side_effect=popen):
            with self.assertRaises(OSError) as caught:controller.main(self.argv)
        self.assertEqual(caught.exception.errno,errno.EAGAIN);self.assert_joined();self.assertEqual(len(self.children),1)

    def test_fixture_log_close_failure_occurs_after_reaping_and_refuses_completion(self):
        real=Path.open
        class CloseFailure:
            def __init__(self,file):self.file=file
            def fileno(self):return self.file.fileno()
            def close(self):self.file.close();raise OSError(errno.ENOSPC,'injected close failure')
        def opened(path,*args,**kwargs):
            file=real(path,*args,**kwargs)
            return CloseFailure(file) if path.name=='fixture.log' else file
        with self.environment(success=True),patch.object(Path,'open',opened):
            with self.assertRaises(RuntimeError):controller.main(self.argv)
        root=self.assert_joined();self.assertEqual(json.loads((root/'controller-final.json').read_text())['state'],'failed')

    def test_resource_append_failure_still_joins_both_handles(self):
        real=Path.open
        class WriteFailure:
            def __init__(self,file):self.file=file
            def __enter__(self):return self
            def __exit__(self,*args):self.file.close()
            def write(self,value):raise OSError(errno.ENOSPC,'injected resource append failure')
            def flush(self):self.file.flush()
        def opened(path,*args,**kwargs):
            file=real(path,*args,**kwargs)
            return WriteFailure(file) if path.name=='resources.jsonl' else file
        with self.environment(),patch.object(Path,'open',opened):
            with self.assertRaises(OSError) as caught:controller.main(self.argv)
        self.assertEqual(caught.exception.errno,errno.ENOSPC);self.assert_joined()

    def test_missing_worker_coverage_preserves_refusal_after_reaping(self):
        self.worker_coverage=False
        with self.environment(success=True):
            with self.assertRaises(RuntimeError):controller.main(self.argv)
        root=self.assert_joined();value=json.loads((root/'controller-final.json').read_text())
        self.assertEqual(value['state'],'refusedBeforeCapture');self.assertTrue(all(x['reaped'] for x in value['cleanup'].values()))

    def test_wrong_provenance_refuses_before_process_or_native_fixture_work(self):
        self.proof.write_text(json.dumps({'bundle':str(self.bundle),'files':{}}))
        with self.environment(),patch.object(controller.subprocess,'run',side_effect=AssertionError('No native work expected')):
            with self.assertRaises(AssertionError):controller.main(self.argv)
        self.assertFalse(self.children)

    def test_success_receipt_is_published_only_after_both_handles_reaped(self):
        real=controller.atomic;observed=False
        def atomic(path,value):
            nonlocal observed
            if path.name=='controller-final.json':
                self.assert_joined();self.assertTrue(all(x['reaped'] for x in value['cleanup'].values()));observed=True
            return real(path,value)
        with self.environment(success=True),patch.object(controller,'atomic',side_effect=atomic):self.assertEqual(controller.main(self.argv),0)
        self.assertTrue(observed);root=self.assert_joined();self.assertEqual(json.loads((root/'controller-final.json').read_text())['state'],'completed')

    def test_failed_final_receipt_does_not_leave_live_children(self):
        real=controller.atomic
        def atomic(path,value):
            if path.name=='controller-final.json':raise OSError(errno.ENOSPC,'injected final receipt failure')
            return real(path,value)
        with self.environment(success=True),patch.object(controller,'atomic',side_effect=atomic):
            with self.assertRaises(OSError):controller.main(self.argv)
        root=self.assert_joined();self.assertFalse((root/'controller-final.json').exists())


if __name__=='__main__':unittest.main(verbosity=2)
