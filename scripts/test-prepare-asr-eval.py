#!/usr/bin/env python3
"""Generated TAR/member, selection, privacy and conversion-failure contracts."""
import contextlib,io,json,pathlib,shutil,sys,tarfile,tempfile,unittest,wave
sys.path.insert(0,str(pathlib.Path(__file__).parent))
from prepare_asr_eval import *
class PreparationTests(unittest.TestCase):
    def fixture(self,root,mode='valid'):
        audio=io.BytesIO()
        with wave.open(audio,'wb') as w:w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000);w.writeframes(b'\0\0'*16000)
        path=root/'source.tar.gz';data=audio.getvalue()
        with tarfile.open(path,'w:gz') as tar:
            def add(name,payload):
                entry=tarfile.TarInfo(name);entry.size=len(payload);tar.addfile(entry,io.BytesIO(payload))
            for speaker in ['1','2']:
                prefix='LibriSpeech/test-clean/'+speaker+'/1/'+speaker+'-1';lines=[]
                for i in range(6):
                    identifier=speaker+'-1-'+str(i).zfill(4);lines.append(identifier+' ALPHA BETA')
                    if mode=='link' and speaker=='1' and i==0:
                        entry=tarfile.TarInfo(prefix+'-'+str(i).zfill(4)+'.flac');entry.type=tarfile.SYMTYPE;entry.linkname='../../../../outside';tar.addfile(entry)
                    else:add(prefix+'-'+str(i).zfill(4)+'.flac',data)
                if mode=='duplicate':lines.append(lines[0])
                add(prefix+'.trans.txt',('\n'.join(lines)+'\n').encode())
            add('../../outside',b'must never extract')
        return path
    def run_prepare(self,archive,output,converter=shutil.copyfile):return prepare({'test-clean':archive},output,expected_md5={'test-clean':fingerprint(archive)['publisher_md5']},converter=converter,conversion_version='generated PCM fixture copy')
    def testFrozenEverySpeakerSelectionAndPrivateFiles(self):
        with tempfile.TemporaryDirectory() as t:
            root=pathlib.Path(t);archive=self.fixture(root);output=root/'prepared'
            with contextlib.redirect_stdout(io.StringIO()):result=self.run_prepare(archive,output)
            self.assertEqual(result['state'],'prepared');self.assertEqual(result['splits'][0]['selected_utterances'],10);self.assertEqual(result['splits'][0]['selected_audio_seconds'],10)
            info=json.loads((output/'test-clean/prepared.json').read_text());self.assertTrue(all(not c['id'].endswith('0005') for c in info['clips']));self.assertEqual(len({c['id'].split('-')[0] for c in info['clips']}),2)
            self.assertEqual((output/'test-clean/audio/1-1-0000.wav').stat().st_mode&0o777,0o600);self.assertFalse((root/'outside').exists())
            before=(output/'manifest.json').read_bytes()
            with self.assertRaisesRegex(ValueError,'must be new'):self.run_prepare(archive,output)
            self.assertEqual((output/'manifest.json').read_bytes(),before)
    def testWrongFingerprintFailsBeforeCreatingOutput(self):
        with tempfile.TemporaryDirectory() as t:
            root=pathlib.Path(t);archive=self.fixture(root);output=root/'bad'
            with self.assertRaisesRegex(ValueError,'fingerprint'):prepare({'test-clean':archive},output,expected_md5={'test-clean':'0'*32})
            self.assertFalse(output.exists())
    def testSelectedSymlinkAndDuplicateReferencesCannotProducePreparedState(self):
        for mode in ['link','duplicate']:
            with tempfile.TemporaryDirectory() as t:
                root=pathlib.Path(t);archive=self.fixture(root,mode);output=root/'bad'
                with self.assertRaises(ValueError):self.run_prepare(archive,output)
                self.assertEqual(json.loads((output/'manifest.json').read_text())['state'],'failed');self.assertFalse((root/'outside').exists())
    def testConversionFailureIsRetainedRatherThanSilentlyDroppingTheClip(self):
        def fail(source,target):raise RuntimeError('fixture converter failed')
        with tempfile.TemporaryDirectory() as t:
            root=pathlib.Path(t);archive=self.fixture(root);output=root/'bad'
            with self.assertRaisesRegex(RuntimeError,'fixture converter'):self.run_prepare(archive,output,fail)
            report=json.loads((output/'manifest.json').read_text());self.assertEqual(report['state'],'failed');self.assertIn('fixture converter',report['failure'])
    def testArchiveMutationDuringConversionCannotComplete(self):
        with tempfile.TemporaryDirectory() as t:
            root=pathlib.Path(t);archive=self.fixture(root);output=root/'bad';changed=False
            def mutate(source,target):
                nonlocal changed
                shutil.copyfile(source,target)
                if not changed:
                    with archive.open('ab') as f:f.write(b'changed archive')
                    changed=True
            with contextlib.redirect_stdout(io.StringIO()),self.assertRaises(ValueError):self.run_prepare(archive,output,mutate)
            self.assertEqual(json.loads((output/'manifest.json').read_text())['state'],'failed')
if __name__=='__main__':unittest.main()
