#!/usr/bin/env python3
"""Generated-data telemetry admission/transport tests; no hardware/network."""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from power_telemetry import FIELDS,TelemetryError,capture,sample


class TelemetryTests(unittest.TestCase):
    def row(self,stamp='2026-10-25T12:00:00Z'):
        return dict.fromkeys(FIELDS,0.25)|dict(timestamp=stamp)

    def test_whitelist_and_zero_preserve_without_availability_inference(self):
        value=self.row()|dict(cpu_power=0,unknown_private_future_field='must not persist')
        result=sample(value)
        self.assertEqual(result['cpu_power'],0);self.assertNotIn('unknown_private_future_field',result)

    def test_nonfinite_negative_boolean_string_and_missing_values_refuse(self):
        for value in [float('nan'),float('inf'),-1,True,'1',None]:
            with self.subTest(value=repr(value)),self.assertRaises(TelemetryError):sample(self.row()|dict(cpu_power=value))
        row=self.row();del row['cpu_power']
        with self.assertRaises(TelemetryError):sample(row)

    def test_timestamp_needs_bounded_aware_instant(self):
        for stamp in ['2026-10-25T12:00:00','invalid','x'*65,None]:
            with self.assertRaises(TelemetryError):sample(self.row(stamp))

    def fake(self,root,body):
        path=root/'fake.py';path.write_text('#!/usr/bin/env python3\nimport sys,json,time,os\n'+body);path.chmod(0o700)
        return path,hashlib.sha256(path.read_bytes()).hexdigest()

    def test_actual_child_boundaries_and_selected_fields(self):
        with tempfile.TemporaryDirectory(prefix='oswind-power-contract-') as folder:
            root=Path(folder);rows=[self.row(),self.row('2026-10-25T12:00:01Z')]
            path,digest=self.fake(root,'rows='+repr(rows)+'\nfor row in rows:print(json.dumps(row),flush=True)\n')
            report=capture(path,samples=2,interval=100,expected_sha256=digest)
            self.assertEqual(len(report['samples']),2);self.assertEqual(report['maximumSampleGapSeconds'],1)
            self.assertGreater(report['childMaximumResidentBytes'],0)

    def test_pinned_identity_refuses_before_launch(self):
        with tempfile.TemporaryDirectory(prefix='oswind-power-contract-') as folder:
            root=Path(folder);marker=root/'launched';path,_=self.fake(root,'open('+repr(str(marker))+',"w").close()\n')
            with self.assertRaises(ValueError):capture(path,samples=1,interval=100,expected_sha256='0'*64)
            self.assertFalse(marker.exists())

    def test_partial_oversized_extra_incomplete_and_repeated_rows_refuse(self):
        with tempfile.TemporaryDirectory(prefix='oswind-power-contract-') as folder:
            root=Path(folder);row=self.row()
            bodies=['sys.stdout.write("{")\n','sys.stdout.write("x"*(256*1024+1))\n','pass\n',
                    'row='+repr(row)+'\nprint(json.dumps(row));print(json.dumps(row))\n']
            for body in bodies:
                path,digest=self.fake(root,body)
                with self.assertRaises(TelemetryError):capture(path,samples=2,interval=100,expected_sha256=digest)
            path,digest=self.fake(root,'row='+repr(row)+'\nprint(json.dumps(row));print(json.dumps(row))\n')
            with self.assertRaises(TelemetryError):capture(path,samples=1,interval=100,expected_sha256=digest)

    def test_rejected_live_child_is_reaped(self):
        with tempfile.TemporaryDirectory(prefix='oswind-power-contract-') as folder:
            root=Path(folder);marker=root/'pid'
            path,digest=self.fake(root,'open('+repr(str(marker))+',"w").write(str(os.getpid()))\nprint("{}",flush=True)\ntime.sleep(30)\n')
            with self.assertRaises(TelemetryError):capture(path,samples=1,interval=100,expected_sha256=digest)
            pid=int(marker.read_text())
            with self.assertRaises(ProcessLookupError):os.kill(pid,0)
            with self.assertRaises(ChildProcessError):os.waitpid(pid,os.WNOHANG)

    def test_threaded_sampling_failure_reaps_without_changing_signal_handlers(self):
        with tempfile.TemporaryDirectory(prefix='oswind-power-contract-') as folder:
            root=Path(folder);marker=root/'pid'
            path,digest=self.fake(root,'open('+repr(str(marker))+',"w").write(str(os.getpid()))\nprint("{}",flush=True)\ntime.sleep(30)\n')
            errors=[]
            def read():
                try:capture(path,samples=1,interval=100,expected_sha256=digest)
                except BaseException as error:errors.append(type(error).__name__)
            thread=threading.Thread(target=read);thread.start();thread.join(timeout=10)
            self.assertFalse(thread.is_alive());self.assertEqual(errors,['TelemetryError'])
            with self.assertRaises(ProcessLookupError):os.kill(int(marker.read_text()),0)


if __name__=='__main__':unittest.main(verbosity=2)
