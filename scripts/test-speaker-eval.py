#!/usr/bin/env python3
import contextlib,hashlib,io,json,os,pathlib,sys,tempfile,unittest,wave
sys.path.insert(0,str(pathlib.Path(__file__).parent))
from speaker_eval import *
from unittest import mock
class MetricContracts(unittest.TestCase):
    def annotation(self,rows):
        result=Annotation(uri='fixture')
        for index,(start,end,label) in enumerate(rows):result[Segment(start,end),index]=label
        return result
    def testPermutationAndUndersegmentation(self):
        ref=self.annotation([(0,1,'A'),(1,2,'B')])
        self.assertAlmostEqual(score(ref,self.annotation([(0,1,'y'),(1,2,'x')]),2)['diarization error rate'],0)
        self.assertAlmostEqual(score(ref,self.annotation([(0,2,'x')]),2)['diarization error rate'],.5)
    def testOverlapAndCollarsAreExplicit(self):
        ref=self.annotation([(0,2,'A'),(1,2,'B')]);hyp=self.annotation([(0,2,'x')])
        self.assertAlmostEqual(score(ref,hyp,2)['diarization error rate'],1/3)
        ref=self.annotation([(0,1,'A'),(1,2,'B')]);hyp=self.annotation([(0,1.1,'x'),(1.1,2,'y')])
        self.assertAlmostEqual(score(ref,hyp,2)['diarization error rate'],.05)
        self.assertAlmostEqual(score(ref,hyp,2,collar=.25)['diarization error rate'],0)
    def testFalseAlarmsCanExceedOneHundredPercentDER(self):
        reference=self.annotation([(0,.1,'A')]);hypothesis=self.annotation([(0,1,'predicted')])
        detail=score(reference,hypothesis,1)
        self.assertAlmostEqual(detail['diarization error rate'],9)
        self.assertAlmostEqual(detail['total'],.1)
    def testWeightedAggregationIsNotMeanOfPercentages(self):
        metric=DiarizationErrorRate(collar=0,skip_overlap=False)
        score(self.annotation([(0,1,'A')]),self.annotation([]),1,metric=metric)
        score(self.annotation([(0,3,'A')]),self.annotation([(0,3,'x')]),3,metric=metric)
        self.assertAlmostEqual(abs(metric),.25)
    def testInvalidTimelinesAndReferenceIdentityAreRejected(self):
        with self.assertRaises(ValueError):read_hypothesis({'scope':'global','duration':1,'turns':[]},'fixture',1)
        with self.assertRaises(ValueError):read_hypothesis({'scope':'recording','duration':1,'turns':[{'start':0,'end':float('nan'),'speaker':'A'}]},'fixture',1)
        with tempfile.TemporaryDirectory() as folder:
            p=pathlib.Path(folder)/'reference.rttm';p.write_text('SPEAKER other 1 0 1 <NA> <NA> A <NA> <NA>\n')
            with self.assertRaises(ValueError):read_reference(p,'fixture',1)
@unittest.skipUnless(sys.platform=='darwin','The harness records macOS /usr/bin/time -l RSS')
class EvaluationProcessContracts(unittest.TestCase):
    def fixture(self,root,corrupt=False):
        dataset=root/'dataset';(dataset/'audio').mkdir(parents=True);(dataset/'reference').mkdir();model=root/'model';model.mkdir();(model/'fixture').write_bytes(b'not a real model')
        manifest={'state':'prepared','dataset':'generated test fixture','annotation_commit':'a'*40,'selection':'two authored files','license':'test fixture','attribution':'OSwind tests','license_source':'fixture only','clips':[]}
        for identifier in ['abcde','bcdef']:
            audio=dataset/'audio'/(identifier+'.wav');ref=dataset/'reference'/(identifier+'.rttm')
            with wave.open(str(audio),'wb') as stream:stream.setnchannels(1);stream.setsampwidth(2);stream.setframerate(16000);stream.writeframes(b'\0\0'*16000)
            ref.write_text(f'SPEAKER {identifier} 1 0 1 <NA> <NA> A <NA> <NA>\n')
            manifest['clips'].append({'id':identifier,'audio_sha256':sha(audio),'reference_sha256':sha(ref)})
        (dataset/'manifest.json').write_text(json.dumps(manifest))
        binary=root/'fake-cli'
        binary.write_text("#!/usr/bin/env python3\nimport json,pathlib,sys\na=sys.argv[1:];source=pathlib.Path(a[a.index('diarize')+1]);out=pathlib.Path(a[a.index('--output')+1]);count=int(a[a.index('--repetitions')+1])\n"+f"if {corrupt!r} and source.stem=='bcdef':\n p=source.with_name('abcde.wav');p.write_bytes(p.read_bytes()+b'changed')\n"+"runs=[{'index':i,'resident_backend_reused':i>0,'seconds':.01,'timeline':{'duration':1,'scope':'recording','model':'explicit synthetic backend','turns':[]}} for i in range(count)]\nout.write_text(json.dumps({'format':'OSwind raw speaker timeline v1','preparation_seconds':.01,'runs':runs}))\n")
        binary.chmod(0o700);return binary,model,dataset
    def testCompletedEvaluationPinsRunnerAndChecksAllSources(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder);binary,model,dataset=self.fixture(root);output=root/'evaluation'
            with contextlib.redirect_stdout(io.StringIO()):report=evaluate(binary,model,dataset,output)
            self.assertEqual(report['state'],'completed');self.assertTrue(report['source_stability_verified']);self.assertEqual(len(report['clips']),2)
            self.assertEqual(sha(output/'runner/oswindctl'),sha(binary));self.assertEqual((output/'runner/oswindctl').stat().st_mode&0o777,0o500)
            self.assertTrue(all(row['micro_der']==1 for row in report['aggregate']));self.assertFalse((output/'forbidden-library').exists())
    def testTestSplitIsLabelledAndReferencesAreParsedOnlyAfterPrediction(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder);binary,model,dataset=self.fixture(root);output=root/'evaluation'
            manifest=json.loads((dataset/'manifest.json').read_text());manifest.update(split='test',coverage='full-test-set',planned_clips=2,available_reference_clips=2);(dataset/'manifest.json').write_text(json.dumps(manifest))
            original=read_reference
            def after_inference(path,identifier,duration):
                self.assertTrue((output/'predictions'/(identifier+'.json')).exists());return original(path,identifier,duration)
            with contextlib.redirect_stdout(io.StringIO()),mock.patch('speaker_eval.read_reference',side_effect=after_inference):report=evaluate(binary,model,dataset,output)
            self.assertEqual(report['dataset']['split'],'test');self.assertEqual(report['selection_coverage']['kind'],'full-test-set');self.assertIn('upstream model-training overlap is unaudited',report['scope']);self.assertTrue(report['settings']['reference_labels_parsed_after_inference'])
    def testIncompleteFullTestAndDuplicateIDsFailBeforeRunnerLaunch(self):
        for duplicate in [False,True]:
            with tempfile.TemporaryDirectory() as folder:
                root=pathlib.Path(folder);binary,model,dataset=self.fixture(root);output=root/'evaluation';manifest=json.loads((dataset/'manifest.json').read_text());manifest.update(split='test',coverage='full-test-set',planned_clips=2,available_reference_clips=3)
                if duplicate:manifest['clips'][1]['id']=manifest['clips'][0]['id'];manifest['available_reference_clips']=2
                (dataset/'manifest.json').write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):evaluate(binary,model,dataset,output)
                self.assertFalse(output.exists())
    def testTerminationRecordsFailureAndStopsActiveInferenceGroup(self):
        import subprocess,signal,time
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder);binary,model,dataset=self.fixture(root);output=root/'evaluation'
            code=binary.read_text().replace("runs=[", "import os,time\nout.with_suffix('.pid').write_text(str(os.getpid()))\ntime.sleep(30)\nruns=[");binary.write_text(code)
            process=subprocess.Popen([sys.executable,str(pathlib.Path(__file__).with_name('speaker_eval.py')),'--binary',str(binary),'--model',str(model),'--dataset',str(dataset),'--output',str(output)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            pidfile=output/'predictions/abcde.pid';deadline=time.monotonic()+10
            while not pidfile.exists() and time.monotonic()<deadline:
                if process.poll() is not None:break
                time.sleep(.02)
            try:
                self.assertTrue(pidfile.exists());child=int(pidfile.read_text());process.send_signal(signal.SIGTERM);process.communicate(timeout=10)
                self.assertNotEqual(process.returncode,0);self.assertEqual(json.loads((output/'report.json').read_text())['state'],'failed')
                with self.assertRaises(ProcessLookupError):os.kill(child,0)
            finally:
                if process.poll() is None:process.kill();process.communicate()
    def testEarlierSourceChangedByLaterInferenceCannotPass(self):
        with tempfile.TemporaryDirectory() as folder:
            root=pathlib.Path(folder);binary,model,dataset=self.fixture(root,corrupt=True);output=root/'evaluation'
            with contextlib.redirect_stdout(io.StringIO()),self.assertRaisesRegex(ValueError,'after corpus inference'):evaluate(binary,model,dataset,output)
            report=json.loads((output/'report.json').read_text());self.assertEqual(report['state'],'failed');self.assertNotIn('aggregate',report)
if __name__=='__main__':unittest.main()
