#!/usr/bin/env python3
"""Independent WER and isolated-import harness contracts; no natural model inference."""
import contextlib,hashlib,io,json,os,pathlib,signal,subprocess,sys,tempfile,time,unittest,wave
sys.path.insert(0,str(pathlib.Path(__file__).parent))
from asr_corpus_eval import *

class WordScoringTests(unittest.TestCase):
    def testPunctuationCaseAndApostrophesAreExplicit(self):
        self.assertEqual(word_counts("DON'T STOP.","Don’t stop!")['wer'],0)
        self.assertEqual(normalized('twenty-one'),'twenty one')
        self.assertNotEqual(word_counts('TWO','2')['wer'],0)
    def testEmptyHypothesisAndInsertionsAreNeverExcludedOrClipped(self):
        row=word_counts('alpha beta','');self.assertEqual(row['deletions'],2);self.assertEqual(row['wer'],1)
        self.assertEqual(word_counts('alpha','beta gamma delta')['wer'],3)
    def testMicroUsesWordCountsNotMeanOfUtteranceRates(self):
        result=micro([word_counts('a',''),word_counts('a b c','a b c')]);self.assertEqual(result['micro_wer'],.25);self.assertEqual(result['reference_words'],4)

@unittest.skipUnless(sys.platform=='darwin','Uses macOS /usr/bin/time -l')
class ASRProcessTests(unittest.TestCase):
    def fixture(self,root,bad_saved=False,mutate=False,pause=False,fail=False):
        dataset=root/'dataset';dataset.mkdir();manifest={'state':'prepared','source':'authored fixture','license':'test fixture','selection':'all generated clips','created_utc':'fixed','splits':[]}
        for split in ['test-clean','test-other']:
            folder=dataset/split;(folder/'audio').mkdir(parents=True);(folder/'reference').mkdir();clips=[]
            for identifier in ['1-1-0000','2-1-0000']:
                audio=folder/'audio'/(identifier+'.wav');flac=audio.with_suffix('.flac');ref=folder/'reference'/(identifier+'.txt')
                with wave.open(str(audio),'wb') as w:w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000);w.writeframes(b'\0\0'*16000)
                flac.write_bytes(b'not decoded by the synthetic CLI');ref.write_text('ALPHA BETA\n')
                clips.append({'id':identifier,'wav_sha256':sha(audio),'flac_sha256':sha(flac),'reference_sha256':sha(ref),'duration_seconds':1})
            info={'split':split,'speakers':2,'selected_utterances':2,'clips':clips};(folder/'prepared.json').write_text(json.dumps(info));(folder/'selection-plan.json').write_text(json.dumps({'split':split,'clips':[{'id':c['id'],'reference_sha256':c['reference_sha256']} for c in clips]}));manifest['splits'].append({'split':split,'speakers':2,'selected_utterances':2})
        (dataset/'manifest.json').write_text(json.dumps(manifest));model=root/'model';model.mkdir();(model/'fixture').write_bytes(b'not a real model');whisper=root/'whisper';whisper.write_bytes(b'not invoked by fake CLI');weights=root/'whisper.bin';weights.write_bytes(b'not a real model')
        binary=root/'fake-cli';binary.write_text("#!/usr/bin/env python3\nimport json,os,pathlib,sqlite3,sys,time\na=sys.argv[1:];library=pathlib.Path(a[a.index('--data')+1]);audio=pathlib.Path(a[a.index('import-audio')+1])\nassert not any('/reference/' in x for x in a)\n"+f"if {fail!r} and audio.stem=='2-1-0000':sys.exit(7)\nif {pause!r}:\n (pathlib.Path(__file__).parent/'active.pid').write_text(str(os.getpid()));time.sleep(30)\nif {mutate!r} and audio.stem=='2-1-0000':\n p=audio.with_name('1-1-0000.wav');p.write_bytes(p.read_bytes()+b'changed')\n"+"memory={'id':'fixture-memory','text':'Alpha beta','transcript':{'text':'Alpha beta','duration':1,'model':'explicit synthetic backend','segments':[]}}\ncon=sqlite3.connect(library/'memory.sqlite');con.execute('CREATE TABLE memories(id TEXT PRIMARY KEY,payload BLOB)')\n"+f"saved=dict(memory,text={'changed' if bad_saved else 'Alpha beta'!r})\n"+"con.execute('INSERT INTO memories VALUES(?,?)',(memory['id'],json.dumps(saved).encode()));con.commit();con.close();print(json.dumps(memory))\n");binary.chmod(0o700);return binary,dataset,model,whisper,weights
    def testCompleteImportCoveragePinningAndIndependentScore(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder);args=self.fixture(root);output=root/'evaluation'
            with contextlib.redirect_stdout(io.StringIO()):report=evaluate(*args,output,trials=2,profiles=['parakeet-neuralEngine','whisper-default'])
            self.assertEqual(report['state'],'completed');self.assertEqual(len(report['measurements']),16);self.assertTrue(report['source_stability_verified']);self.assertEqual(len(report['aggregate']),8);self.assertTrue(all(x['micro_wer']==0 for x in report['aggregate']));self.assertEqual((output/'runner/oswindctl').stat().st_mode&0o777,0o500)
            before=(output/'report.json').read_bytes()
            with self.assertRaisesRegex(ValueError,'must be new'):evaluate(*args,output)
            self.assertEqual((output/'report.json').read_bytes(),before)
    def testFailedImportsRemainInCoverageAndEndToEndDenominator(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder);args=self.fixture(root,fail=True);output=root/'evaluation'
            with contextlib.redirect_stdout(io.StringIO()):report=evaluate(*args,output,trials=2,profiles=['whisper-default'])
            self.assertEqual(report['state'],'completed');self.assertTrue(report['source_stability_verified']);self.assertFalse(report['all_imports_succeeded']);self.assertEqual(report['failed_imports'],4);self.assertEqual(len(report['measurements']),8)
            for row in report['aggregate']:
                self.assertEqual(row['utterances'],2);self.assertEqual(row['failed_imports'],1);self.assertEqual(row['successful_imports'],1);self.assertEqual(row['micro_wer'],.5);self.assertEqual(row['successful_import_scores']['micro_wer'],0)
            failed=[r for r in report['measurements'] if not r['import_succeeded']]
            self.assertTrue(all(r['exit_code']==7 and r['scores']['deletions']==2 and not r['saved_record_verified'] and r['saved_record_count']==0 for r in failed))
    def testResponseCannotSubstituteForActualSavedRecord(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder);args=self.fixture(root,bad_saved=True);output=root/'evaluation'
            with self.assertRaisesRegex(ValueError,'saved record'):evaluate(*args,output,trials=1,profiles=['parakeet-neuralEngine'])
            report=json.loads((output/'report.json').read_text());self.assertEqual(report['state'],'failed');self.assertNotIn('aggregate',report)
    def testLaterImportCannotChangeAnEarlierSourceAndStillPass(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder);args=self.fixture(root,mutate=True);output=root/'evaluation'
            with contextlib.redirect_stdout(io.StringIO()),self.assertRaisesRegex(ValueError,'source drift'):evaluate(*args,output,trials=1,profiles=['parakeet-neuralEngine'])
            self.assertEqual(json.loads((output/'report.json').read_text())['state'],'failed')
    def testFrozenPlanMismatchFailsBeforeOutputOrModelWork(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder);args=self.fixture(root);path=args[1]/'test-clean/selection-plan.json';plan=json.loads(path.read_text());plan['clips'].pop();path.write_text(json.dumps(plan));output=root/'evaluation'
            with self.assertRaisesRegex(ValueError,'frozen IDs'):evaluate(*args,output)
            self.assertFalse(output.exists())
    def testTerminationStopsTheInferenceAndRecordsFailure(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder);binary,dataset,model,whisper,weights=self.fixture(root,pause=True);output=root/'evaluation'
            process=subprocess.Popen([sys.executable,str(pathlib.Path(__file__).with_name('asr_corpus_eval.py')),'--binary',str(binary),'--dataset',str(dataset),'--native-model',str(model),'--whisper-binary',str(whisper),'--whisper-model',str(weights),'--output',str(output),'--profiles','parakeet-neuralEngine'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            pidfile=output/'runner/active.pid';deadline=time.monotonic()+10
            while not pidfile.exists() and time.monotonic()<deadline:
                if process.poll() is not None:break
                time.sleep(.02)
            try:
                self.assertTrue(pidfile.exists());child=int(pidfile.read_text());process.send_signal(signal.SIGTERM);process.communicate(timeout=10);self.assertNotEqual(process.returncode,0);self.assertEqual(json.loads((output/'report.json').read_text())['state'],'failed')
                with self.assertRaises(ProcessLookupError):os.kill(child,0)
            finally:
                if process.poll() is None:process.kill();process.communicate()
if __name__=='__main__':unittest.main()
