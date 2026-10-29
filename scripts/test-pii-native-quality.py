#!/usr/bin/env python3
import copy
import hashlib
import unittest
import pii_native_quality as n
import pii_quality as q

LABELS={'password':'secret'}

def payload():
    text='🔒 e\u0301 secret done'
    value=dict(sourceSHA256=hashlib.sha256(text.encode()).hexdigest(),modelID=n.MODEL_PREFIX+'cpu',compute='cpu',threshold=.7,
               windowCount=1,framedTokens=90,text='🔒 e\u0301 [REDACTED] done',
               spans=[dict(startUTF16=6,lengthUTF16=6,label='password',category='secret',confidence=.8)],
               modelMasks=[dict(startUTF16=6,lengthUTF16=6)],masks=[dict(startUTF16=6,lengthUTF16=6)],
               modelRedacted=True,patternRedacted=False,redacted=True,suppressMedia=True)
    return text,value

class Tests(unittest.TestCase):
    def validate(self,text,value):return n.validate_native(text,value,'cpu',.7,LABELS)
    def test_unicode_offsets_render_and_full_value_scoring(self):
        text,value=payload();result=self.validate(text,value)
        self.assertEqual(result['hybrid'],[dict(start=5,end=11,label='masks')])
        row=dict(id='owned',text=text,gold=[dict(start=5,end=11,label='secret')])
        score=q.evaluate([row],[dict(id='owned',sourceSHA256=result['sourceSHA256'],spans=result['hybrid'])],{'secret','masks'})
        self.assertEqual(score['fullyCoveredValues'],1);self.assertEqual(score['characterCoverageUntyped']['f1'],1)
    def test_changed_identity_threshold_and_compute_refused(self):
        for key,changed in [('sourceSHA256','bad'),('modelID','other'),('compute','coreML'),('threshold',.5),('threshold',float('nan'))]:
            text,value=payload();value[key]=changed
            with self.subTest(key=key),self.assertRaises(ValueError):self.validate(text,value)
    def test_surrogate_splits_invalid_bounds_and_boolean_offsets_refused(self):
        for changed in [dict(startUTF16=1,lengthUTF16=1),dict(startUTF16=-1,lengthUTF16=1),dict(startUTF16=True,lengthUTF16=1),dict(startUTF16=6,lengthUTF16=0),dict(startUTF16=6,lengthUTF16=999)]:
            text,value=payload();value['masks']=[changed]
            with self.subTest(changed=changed),self.assertRaises(ValueError):self.validate(text,value)
    def test_changed_render_and_dropped_learned_mask_refused(self):
        for change in [dict(text='wrong'),dict(masks=[]),dict(modelMasks=[])]:
            text,value=payload();value.update(change)
            with self.subTest(change=change),self.assertRaises(ValueError):self.validate(text,value)
    def test_touching_overlapping_unsorted_duplicate_masks_refused(self):
        cases=[[dict(startUTF16=6,lengthUTF16=3),dict(startUTF16=9,lengthUTF16=3)],
               [dict(startUTF16=6,lengthUTF16=6)]*2,
               [dict(startUTF16=10,lengthUTF16=2),dict(startUTF16=6,lengthUTF16=2)]]
        for masks in cases:
            text,value=payload();value['masks']=masks
            with self.subTest(masks=masks),self.assertRaises(ValueError):self.validate(text,value)
    def test_wrong_category_confidence_and_duplicate_span_refused(self):
        for change in [dict(category='email'),dict(label='unknown'),dict(confidence=float('nan')),dict(confidence=True),dict(confidence=1.1)]:
            text,value=payload();value['spans'][0].update(change)
            with self.subTest(change=change),self.assertRaises(ValueError):self.validate(text,value)
        text,value=payload();value['spans']*=2
        with self.assertRaises(ValueError):self.validate(text,value)
    def test_inconsistent_flags_and_document_budget_refused(self):
        for change in [dict(modelRedacted=False),dict(redacted=False),dict(suppressMedia=False),dict(patternRedacted=1),dict(windowCount=0),dict(windowCount=True),dict(framedTokens=65537)]:
            text,value=payload();value.update(change)
            with self.subTest(change=change),self.assertRaises(ValueError):self.validate(text,value)
    def test_literal_marker_without_masks_is_not_an_inferred_redaction(self):
        text='Literal [REDACTED] placeholder';_,value=payload();value.update(sourceSHA256=hashlib.sha256(text.encode()).hexdigest(),text=text,spans=[],masks=[],modelMasks=[],modelRedacted=False,patternRedacted=False,redacted=False,suppressMedia=False)
        result=self.validate(text,value);self.assertFalse(result['redacted']);self.assertEqual(result['hybrid'],[])
    def test_partial_value_mask_is_not_full_coverage(self):
        text,value=payload();value['spans'][0]['lengthUTF16']=3;value['masks'][0]['lengthUTF16']=3;value['modelMasks'][0]['lengthUTF16']=3;value['text']='🔒 e\u0301 [REDACTED]ret done'
        result=self.validate(text,value);row=dict(id='owned',text=text,gold=[dict(start=5,end=11,label='secret')])
        score=q.evaluate([row],[dict(id='owned',sourceSHA256=result['sourceSHA256'],spans=result['hybrid'])],{'secret','masks'})
        self.assertEqual(score['fullyCoveredValues'],0)
    def test_additional_hybrid_mask_preserves_source_and_changes_whole_value_coverage(self):
        text='x mmmm y pppp z';_,value=payload()
        value.update(sourceSHA256=hashlib.sha256(text.encode()).hexdigest(),text='x [REDACTED] y [REDACTED] z',
                     modelMasks=[dict(startUTF16=2,lengthUTF16=4)],masks=[dict(startUTF16=2,lengthUTF16=4),dict(startUTF16=9,lengthUTF16=4)],patternRedacted=True,
                     spans=[dict(startUTF16=2,lengthUTF16=4,label='password',category='secret',confidence=.8)])
        parsed=self.validate(text,value);row=dict(id='owned',text=text,gold=[dict(start=2,end=6,label='secret'),dict(start=9,end=13,label='secret')])
        scores=[]
        for kind in ['model','hybrid']:
            scores.append(q.evaluate([row],[dict(id='owned',sourceSHA256=parsed['sourceSHA256'],spans=parsed[kind])],{'secret','modelMasks','masks'})['fullyCoveredValues'])
        self.assertEqual(scores,[1,2])
        value['patternRedacted']=False
        with self.assertRaises(ValueError):self.validate(text,value)

if __name__=='__main__':unittest.main()
