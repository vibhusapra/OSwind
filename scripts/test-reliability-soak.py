#!/usr/bin/env python3
"""Harness contracts and a short actual pinned-CLI/MCP run, without downloads."""
import argparse,contextlib,hashlib,importlib.util,io,json,os,pathlib,subprocess,sys,tempfile,time,unittest
from unittest import mock
p=argparse.ArgumentParser();p.add_argument('binary');a=p.parse_args();binary=pathlib.Path(a.binary).resolve();script=pathlib.Path(__file__).with_name('reliability-soak.py').resolve()
spec=importlib.util.spec_from_file_location('soak',script);soak=importlib.util.module_from_spec(spec);spec.loader.exec_module(soak)
class Contracts(unittest.TestCase):
    def test_real_pinned_process_write_read_erase_and_clean_shutdown(self):
        with tempfile.TemporaryDirectory(prefix='oswind-soak-contract-') as base:
            root=pathlib.Path(base)/'run';forbidden=pathlib.Path(base)/'normal-root-must-not-open'
            result=subprocess.run([sys.executable,str(script),str(binary),'--root',str(root),'--seconds','4','--interval','2','--max-notes','1'],capture_output=True,text=True,timeout=90,env={**os.environ,'OSWIND_DATA_DIR':str(forbidden)})
            self.assertEqual(result.returncode,0,result.stderr+result.stdout)
            status=json.loads((root/'status.json').read_text());self.assertEqual(status['state'],'passed');self.assertGreaterEqual(status['writes'],2);self.assertGreaterEqual(status['deletions'],1);self.assertGreaterEqual(status['writer_live_read_cycles'],1)
            self.assertEqual(status['mcp_shutdown'],{'exit_code':0,'forced':False});self.assertFalse(forbidden.exists())
            runner=root/'runner/oswindctl'
            self.assertEqual(soak.digest(runner),status['binary_sha256'])
            self.assertEqual(runner.stat().st_mode&0o222,0)
            samples=[json.loads(line) for line in (root/'samples.jsonl').read_text().splitlines()];self.assertEqual(len(samples),status['cycles']);self.assertEqual(samples[-1]['source_count'],3)
    def test_existing_root_is_preserved(self):
        with tempfile.TemporaryDirectory() as root:
            marker=pathlib.Path(root)/'keep.txt';marker.write_text('preserve')
            result=subprocess.run([sys.executable,str(script),str(binary),'--root',root,'--seconds','1'],capture_output=True,text=True,timeout=10)
            self.assertNotEqual(result.returncode,0);self.assertEqual(marker.read_text(),'preserve');self.assertEqual(list(pathlib.Path(root).iterdir()),[marker])
    def test_failed_prepare_is_terminal_and_recorded(self):
        with tempfile.TemporaryDirectory() as base:
            root=pathlib.Path(base)/'run';failure=pathlib.Path(base)/'fail';failure.write_text('#!/bin/sh\nexit 1\n');failure.chmod(0o700)
            result=subprocess.run([sys.executable,str(script),str(failure),'--root',str(root),'--seconds','1'],capture_output=True,text=True,timeout=10)
            self.assertNotEqual(result.returncode,0);status=json.loads((root/'status.json').read_text());self.assertEqual(status['state'],'failed');self.assertEqual(status['cycles'],0);self.assertNotIn('mcp_pid',status)
    def test_simulated_clock_gap_cannot_be_reported_as_continuous_pass(self):
        with tempfile.TemporaryDirectory() as base:
            root=pathlib.Path(base)/'gap';clock=soak.time.time;offset=[0]
            def gap(_):offset[0]+=20
            arguments=[str(script),str(binary),'--root',str(root),'--seconds','4','--interval','1']
            with mock.patch.object(sys,'argv',arguments),mock.patch.object(soak.time,'time',side_effect=lambda:clock()+offset[0]),mock.patch.object(soak.time,'sleep',side_effect=gap),contextlib.redirect_stdout(io.StringIO()):
                code=soak.main()
            status=json.loads((root/'status.json').read_text());self.assertEqual(code,3);self.assertEqual(status['state'],'completed_with_gaps');self.assertTrue(status['oversize_wall_gaps']);self.assertFalse(status['mcp_shutdown']['forced'])
    def test_pinning_failure_is_recorded_without_starting_a_child(self):
        with tempfile.TemporaryDirectory() as base:
            root=pathlib.Path(base)/'pin';arguments=[str(script),str(binary),'--root',str(root),'--seconds','1']
            with mock.patch.object(sys,'argv',arguments),mock.patch.object(soak.shutil,'copy2',side_effect=PermissionError('simulated pin refusal')):
                code=soak.main()
            status=json.loads((root/'status.json').read_text());self.assertEqual(code,1);self.assertEqual(status['stage'],'pinning');self.assertEqual(status['state'],'failed');self.assertFalse((root/'library').exists())
    def test_termination_records_interruption_and_closes_persistent_child(self):
        with tempfile.TemporaryDirectory() as base:
            root=pathlib.Path(base)/'interrupted'
            process=subprocess.Popen([sys.executable,str(script),str(binary),'--root',str(root),'--seconds','120','--interval','2'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                deadline=time.monotonic()+20;state={}
                while time.monotonic()<deadline:
                    if (root/'status.json').exists():state=json.loads((root/'status.json').read_text())
                    if state.get('state')=='running':break
                    if process.poll() is not None:self.fail(process.communicate()[1])
                    time.sleep(.05)
                self.assertEqual(state.get('state'),'running');process.terminate();output,error=process.communicate(timeout=20)
                self.assertEqual(process.returncode,130,error+output)
                status=json.loads((root/'status.json').read_text());self.assertEqual(status['state'],'interrupted');self.assertEqual(status['mcp_shutdown'],{'exit_code':0,'forced':False})
            finally:
                if process.poll() is None:process.kill();process.communicate(timeout=10)
    def fake(self,root,bad=False):
        path=pathlib.Path(root)/'fake.py'
        path.write_text('import json,sys,time\nfor line in sys.stdin:\n r=json.loads(line)\n if "id" not in r:continue\n if r["method"]=="slow":time.sleep(.6)\n print(json.dumps({"jsonrpc":"2.0","id":'+('-1' if bad else 'r["id"]')+',"result":{}}),flush=True)\n')
        return [sys.executable,'-u',str(path)]
    def test_response_timeout_does_not_infer_exit_or_restart(self):
        with tempfile.TemporaryDirectory() as root,tempfile.TemporaryFile(mode='w+') as log:
            client=soak.MCP(self.fake(root),log,5);pid=client.process.pid;client.timeout=.05
            try:
                with self.assertRaisesRegex(RuntimeError,'deadline exceeded'):client.call('slow',{})
                self.assertIsNone(client.process.poll());self.assertEqual(client.process.pid,pid)
            finally:self.assertEqual(client.close(),{'exit_code':0,'forced':False})
    def test_bad_initialization_cleans_its_child(self):
        with tempfile.TemporaryDirectory() as root,tempfile.TemporaryFile(mode='w+') as log:
            client=soak.MCP.__new__(soak.MCP)
            with self.assertRaisesRegex(RuntimeError,'Invalid MCP response'):client.__init__(self.fake(root,bad=True),log,5)
            self.assertIsNotNone(client.process.poll())

unittest.main(argv=[sys.argv[0]])
