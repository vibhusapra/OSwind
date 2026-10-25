"""Generated protocol-adversary checks; no real library, model, service or key."""
import concurrent.futures
import json
from pathlib import Path
import tempfile
import time
import unittest
from oswind import Client, OSwindError

MOCK = '''#!/usr/bin/env python3
import json,sys,time
mode=MODE
for line in sys.stdin:
 r=json.loads(line)
 if 'id' not in r:continue
 if r['method']=='initialize':
  value={'protocolVersion':'2025-11-25'}
  print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':value}),flush=True);continue
 if mode=='partial':sys.stdout.write('{"private-synthetic-marker":');sys.stdout.flush();time.sleep(5);continue
 if mode=='oversize':print('x'*40000,flush=True);continue
 if mode=='badjson':print('private-synthetic-marker{',flush=True);continue
 if mode=='eof':sys.exit(0)
 if mode=='stderr':sys.stderr.write('x'*200000);sys.stderr.flush()
 if mode=='flood':
  for _ in range(18):print(json.dumps({'jsonrpc':'2.0','method':'notifications/progress'}),flush=True)
 if mode=='request_error':reply={'jsonrpc':'2.0','id':r['id'],'error':{'message':'private-synthetic-marker'}}
 elif mode=='wrongid':reply={'jsonrpc':'2.0','id':True,'result':{}}
 else:
  value=({'tools':[]} if r['method']=='tools/list' else {'content':[{'type':'text','text':json.dumps(r.get('params',{}).get('arguments',{}))}]})
  reply={'jsonrpc':'2.0','id':r['id'],'result':value}
 print(json.dumps(reply),flush=True)
'''


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='oswind-sdk-protocol-')
        self.root = Path(self.directory.name)
        self.data = self.root/'Library'
        self.data.mkdir()

    def tearDown(self):
        self.directory.cleanup()

    def client(self, mode, **options):
        path=self.root/(mode+'.py')
        path.write_text(MOCK.replace('MODE',repr(mode)))
        path.chmod(0o700)
        return Client(path,self.data,**options)

    def test_partial_line_respects_deadline_and_reaps_owned_child(self):
        with self.client('partial',timeout=10) as client:
            client.timeout=.3  # Bound partial response after observed negotiation.
            start=time.monotonic()
            with self.assertRaisesRegex(OSwindError,'timed out'):client.stats()
            self.assertLess(time.monotonic()-start,3)
            self.assertIsNotNone(client._process.poll())
            with self.assertRaisesRegex(OSwindError,'closed'):client.stats()

    def test_oversized_unterminated_reply_is_bounded_and_reaped(self):
        with self.client('oversize',max_response_bytes=1024) as client:
            with self.assertRaisesRegex(OSwindError,'byte bound'):client.stats()
            self.assertLessEqual(len(client._buffer),1024)
            self.assertIsNotNone(client._process.poll())

    def test_malformed_payload_does_not_enter_exception_text(self):
        with self.client('badjson') as client:
            with self.assertRaises(OSwindError) as error:client.stats()
            self.assertNotIn('private-synthetic-marker',str(error.exception))
            self.assertIsNotNone(client._process.poll())

    def test_boolean_response_id_cannot_match_integer_request(self):
        with self.client('wrongid') as client:
            with self.assertRaisesRegex(OSwindError,'identity mismatch'):client.stats()
            self.assertIsNotNone(client._process.poll())

    def test_unbounded_notifications_fail_closed(self):
        with self.client('flood') as client:
            with self.assertRaisesRegex(OSwindError,'notification budget'):client.stats()
            self.assertIsNotNone(client._process.poll())

    def test_eof_is_explicit_and_closes_client(self):
        with self.client('eof') as client:
            with self.assertRaisesRegex(OSwindError,'closed the protocol'):client.stats()
            self.assertIsNotNone(client._process.poll())

    def test_remote_protocol_error_does_not_echo_payload(self):
        with self.client('request_error') as client:
            with self.assertRaises(OSwindError) as error:client.stats()
            self.assertNotIn('private-synthetic-marker',str(error.exception))
            self.assertIsNotNone(client._process.poll())

    def test_stderr_cannot_fill_pipe_and_stall_read(self):
        with self.client('stderr',timeout=2) as client:
            self.assertEqual(client.stats(),{})

    def test_threads_receive_their_own_serialized_response(self):
        with self.client('ok') as client:
            with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
                values=list(executor.map(lambda i:client.call('memory_stats',token=i),range(20)))
            self.assertEqual(values,[{'token':i} for i in range(20)])

    def test_large_request_refuses_without_echo_and_reaps(self):
        with self.client('ok') as client:
            with self.assertRaisesRegex(OSwindError,'exceeds 1 MB'):client.search('synthetic-'*150000)
            self.assertIsNotNone(client._process.poll())

    def test_only_known_read_tools_are_exposed_and_client_remains_usable(self):
        with self.client('ok') as client:
            with self.assertRaises(ValueError):client.call('shell',command='ignored')
            self.assertEqual(client.tools(),[])
            self.assertEqual(client.search('Zoë 😀',app='Fixture'),{'query':'Zoë 😀','mode':'keyword','limit':20,'detail':'preview','app':'Fixture'})

    def test_explicit_close_is_idempotent_and_bounds_are_validated(self):
        client=self.client('ok');client.close();client.close()
        self.assertIsNotNone(client._process.poll())
        with self.assertRaises(ValueError):Client(Path('relative'),self.data)
        with self.assertRaises(ValueError):self.client('ok',timeout=float('nan'))
        with self.assertRaises(ValueError):self.client('ok',max_response_bytes=True)


if __name__=='__main__':unittest.main()
