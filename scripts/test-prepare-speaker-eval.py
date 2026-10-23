#!/usr/bin/env python3
"""Offline HTTP/entity and local extraction contracts, with generated WAV bytes."""
import contextlib,hashlib,importlib.util,io,json,pathlib,re,tempfile,threading,unittest,wave,zipfile
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
spec=importlib.util.spec_from_file_location('prepare',pathlib.Path(__file__).with_name('prepare-speaker-eval.py'));module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class PreparationContracts(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.temporary.name)
        wav=io.BytesIO()
        with wave.open(wav,'wb') as stream:stream.setnchannels(1);stream.setsampwidth(2);stream.setframerate(16000);stream.writeframes(b'\0\0'*16000)
        self.wav=wav.getvalue();archive=io.BytesIO()
        with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED) as z:z.writestr('audio/abcde.wav',self.wav)
        self.payload=archive.getvalue();self.state={'mode':'valid','requests':[]}
        payload,state=self.payload,self.state
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_HEAD(self):self.send_response(200);self.send_header('Content-Length',str(len(payload)));self.send_header('ETag','"fixed"');self.end_headers()
            def do_GET(self):
                state['requests'].append(dict(self.headers));match=re.fullmatch(r'bytes=(\d+)-(\d+)',self.headers.get('Range',''));assert match
                start,end=map(int,match.groups());body=payload[start:end+1]
                self.send_response(200 if state['mode']=='ignored' else 206);self.send_header('Content-Length',str(len(body)));self.send_header('ETag','"changed"' if state['mode']=='changed' else '"fixed"');self.send_header('Content-Range',f'bytes {start}-{end}/{len(payload)+(1 if state["mode"]=="wrong-range" else 0)}');self.end_headers();self.wfile.write(body)
        self.server=ThreadingHTTPServer(('127.0.0.1',0),Handler);self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start();self.url=f'http://127.0.0.1:{self.server.server_port}/source.zip'
    def tearDown(self):self.server.shutdown();self.server.server_close();self.thread.join();self.temporary.cleanup()
    def testExactRangeAndZipCRCProduceOriginalMember(self):
        with module.RangeFile(self.url) as remote,zipfile.ZipFile(remote) as archive:self.assertEqual(archive.read('audio/abcde.wav'),self.wav)
        self.assertTrue(self.state['requests']);self.assertTrue(all(r['If-Range']=='"fixed"' for r in self.state['requests']))
    def testEntityChangesAndIgnoredOrWrongRangesFailClosed(self):
        for mode in ['changed','ignored','wrong-range']:
            with self.subTest(mode=mode):
                self.state['mode']=mode
                with module.RangeFile(self.url) as remote:
                    with self.assertRaises(ValueError):remote.read(20)
    def testRangeBoundsDoNotTriggerLargeFetch(self):
        with module.RangeFile(self.url) as remote:
            with self.assertRaises(ValueError):remote.seek(-1)
            with self.assertRaises(ValueError):remote.seek(remote.length+1)
            remote.seek(0,2);self.assertEqual(remote.read(),b'')
        self.assertEqual(self.state['requests'],[])
    def testPinnedReferencesPrivateAssetsAndExistingOutputPreserved(self):
        audio=self.root/'audio.zip';audio.write_bytes(self.payload);annotations=self.root/'annotations.zip';member='joonson-voxconverse-aaaaaaa/dev/abcde.rttm';data=b'SPEAKER abcde 1 0 1 <NA> <NA> A <NA> <NA>\n'
        with zipfile.ZipFile(annotations,'w') as z:z.writestr(member,data)
        plan={'annotation_commit':'a'*40,'selection':'test only','clips':[{'id':'abcde','annotation_member':member,'annotation_sha256':hashlib.sha256(data).hexdigest()}]}
        output=self.root/'prepared';result=module.prepare(annotations,plan,output,audio)
        self.assertEqual(result['state'],'prepared');self.assertEqual((output/'audio/abcde.wav').read_bytes(),self.wav);self.assertEqual((output/'audio/abcde.wav').stat().st_mode&0o777,0o600)
        before=(output/'manifest.json').read_bytes()
        with self.assertRaises(ValueError):module.prepare(annotations,plan,output,audio)
        self.assertEqual((output/'manifest.json').read_bytes(),before)
        plan['clips'][0]['annotation_sha256']='0'*64
        with self.assertRaises(ValueError):module.prepare(annotations,plan,self.root/'bad-reference',audio)
        self.assertEqual(json.loads((self.root/'bad-reference/manifest.json').read_text())['state'],'failed')
    def testWholeDevelopmentCoverageAndLargerFixedSelection(self):
        audio=self.root/'many.zip';annotations=self.root/'references.zip';clips=[]
        with zipfile.ZipFile(audio,'w',compression=zipfile.ZIP_DEFLATED) as wavs,zipfile.ZipFile(annotations,'w') as refs:
            for index in range(21):
                identifier='aaaa'+chr(ord('a')+index);member='joonson-voxconverse-aaaaaaa/dev/'+identifier+'.rttm'
                data=f'SPEAKER {identifier} 1 0 1 <NA> <NA> A <NA> <NA>\n'.encode()
                wavs.writestr(identifier+'.wav',self.wav);refs.writestr(member,data);clips.append({'id':identifier,'annotation_member':member,'annotation_sha256':hashlib.sha256(data).hexdigest()})
        plan={'annotation_commit':'a'*40,'selection':'all generated references','coverage':'full-development-set','clips':clips}
        with contextlib.redirect_stdout(io.StringIO()):result=module.prepare(annotations,plan,self.root/'full',audio)
        self.assertEqual(result['state'],'prepared');self.assertEqual(result['coverage'],'full-development-set');self.assertEqual(result['available_reference_clips'],21)
        plan['clips']=clips[:-1]
        with self.assertRaisesRegex(ValueError,'does not equal'):module.prepare(annotations,plan,self.root/'incomplete',audio)
        self.assertEqual(json.loads((self.root/'incomplete/manifest.json').read_text())['state'],'failed')
    def testOversizedSelectionFailsBeforeCreatingOutput(self):
        def identifier(number):
            letters=[]
            for _ in range(5):letters.append(chr(ord('a')+number%26));number//=26
            return ''.join(reversed(letters))
        plan={'annotation_commit':'a'*40,'selection':'oversize','clips':[{'id':identifier(i)} for i in range(513)]}
        output=self.root/'oversized'
        with self.assertRaisesRegex(ValueError,'Invalid fixed'):module.prepare(self.root/'unused',plan,output,self.root/'unused-audio')
        self.assertFalse(output.exists())
if __name__=='__main__':unittest.main()
