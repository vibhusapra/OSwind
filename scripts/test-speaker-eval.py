#!/usr/bin/env python3
import pathlib,sys,tempfile,unittest
sys.path.insert(0,str(pathlib.Path(__file__).parent))
from speaker_eval import *
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
if __name__=='__main__':unittest.main()
