import dataclasses
from datetime import datetime,timezone,timedelta
import json
from pathlib import Path
import tempfile
import unittest
from oswind import OSwindError
from oswind.collector import Batch,Record,submit

class CollectorContractTests(unittest.TestCase):
    def record(self,key='ticket-123',**changes):
        r=Record(key,datetime(2026,10,25,5,23,45,123456,timezone(timedelta(hours=-7))),'Tickets','dev.example.tickets','Launch','Authored source text','https://example.com/ticket/123')
        return dataclasses.replace(r,**changes)

    def test_frozen_identity_and_fractional_time_and_exact_unicode_keys(self):
        x=Batch('dev.example.tickets',[self.record()]);self.assertEqual(x.ids[0],'collector:dev.example.tickets:750e2f6fb300f764f94a0e110ed83aeae5b816bf9e20db82b46bdc777e4fd616')
        self.assertEqual(json.loads(x.encode())['records'][0]['timestamp'],'2026-10-25T12:23:45.123456Z')
        self.assertNotEqual(x.ids,Batch('dev.other.tickets',[self.record()]).ids)
        y=Batch('dev.example.tickets',[self.record('é'),self.record('e\u0301')]);self.assertNotEqual(y.ids[0],y.ids[1])
        with self.assertRaises(ValueError):Batch('dev.example.tickets',[self.record(),self.record()])

    def test_unbounded_iterable_and_batch_bytes_refuse_before_process(self):
        with self.assertRaises(ValueError):Batch('dev.example.tickets',(self.record(str(i)) for i in range(2000)))
        large=Batch('dev.example.tickets',[self.record(str(i),text='x'*(1024*1024)) for i in range(17)])
        with self.assertRaisesRegex(ValueError,'16 MiB'):large.encode()
        with self.assertRaises(ValueError):Batch('dev.example.tickets',[self.record(timestamp=datetime(2026,1,1))])
        with self.assertRaises(ValueError):Batch('dev.example.tickets',[self.record(url='https://user:secret@example.com')])
        with self.assertRaises(ValueError):Batch('dev.example.tickets',[self.record(url='https://@example.com')])

    def fake(self,root,body):
        p=root/'fake.py';p.write_text('#!/usr/bin/env python3\nimport json,sys,time,hashlib\n'+body);p.chmod(0o700);return p

    def test_actual_pipe_submission_and_identity_refusal(self):
        with tempfile.TemporaryDirectory(prefix='oswind-sdk-collector-') as d:
            root=Path(d);batch=Batch('dev.example.tickets',[self.record()])
            body="x=json.load(sys.stdin)\nr=dict(format='OSwind collector result',version=1,collectorID=x['collectorID'],requested=len(x['records']),imported=len(x['records']),excluded=0,sourceIDs=['collector:'+x['collectorID']+':'+hashlib.sha256(v['key'].encode()).hexdigest() for v in x['records']])\nprint(json.dumps(r))\n"
            exe=self.fake(root,body)
            self.assertEqual(submit(exe,root,batch)['imported'],1)
            exe=self.fake(root,body.replace("print(json.dumps(r))","r['sourceIDs']=['wrong-source'];print(json.dumps(r))"))
            with self.assertRaisesRegex(OSwindError,'identity'):submit(exe,root,batch)

    def test_partial_output_deadline_and_oversized_report(self):
        with tempfile.TemporaryDirectory(prefix='oswind-sdk-collector-') as d:
            root=Path(d);batch=Batch('dev.example.tickets',[self.record()])
            # Read/parse first, then partial reply: interpreter startup has its own margin.
            exe=self.fake(root,"json.load(sys.stdin)\nopen(sys.argv[2]+'/payload-read','w').close()\nsys.stdout.write('{');sys.stdout.flush();time.sleep(5)\n")
            with self.assertRaises(OSwindError):submit(exe,root,batch,timeout=2)
            self.assertTrue((root/'payload-read').exists())
            exe=self.fake(root,"json.load(sys.stdin)\nsys.stdout.write('x'*(2*1024*1024));sys.stdout.flush()\n")
            with self.assertRaisesRegex(OSwindError,'1 MiB'):submit(exe,root,batch)

if __name__=='__main__':unittest.main()
