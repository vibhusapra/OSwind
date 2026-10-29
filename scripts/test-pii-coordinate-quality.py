#!/usr/bin/env python3
import copy
import hashlib
import unittest
import pii_quality as literal
import pii_coordinate_quality as c

LABELS={'secret','masks'}


def fixture():
    text='🔒 Cafe\u0301 secret note'
    source=dict(id='owned',textCharacters=len(text),sourceSHA256=hashlib.sha256(text.encode()).hexdigest(),gold=[dict(start=8,end=14,label='secret')])
    result=dict(id='owned',sourceSHA256=source['sourceSHA256'],spans=[dict(start=8,end=14,label='secret',score=.8)])
    return text,source,result


class Tests(unittest.TestCase):
    def test_full_partial_wrong_category_and_extra_coverage(self):
        _,row,result=fixture();self.assertEqual(c.evaluate([row],[result],LABELS)['fullyCoveredValues'],1)
        result['spans'][0]['end']-=1;self.assertEqual(c.evaluate([row],[result],LABELS)['fullyCoveredValues'],0)
        result['spans'][0].update(end=14,label='masks');m=c.evaluate([row],[result],LABELS)
        self.assertEqual(m['fullyCoveredValues'],1);self.assertEqual(m['exactTypedSpans']['tp'],0)
        result['spans'][0]['start']-=1;m=c.evaluate([row],[result],LABELS)
        self.assertEqual(m['characterCoverageUntyped']['fp'],1)
    def test_literal_and_coordinate_metrics_match_on_owned_unicode_cases(self):
        text,row,result=fixture()
        for spans in [[],result['spans'],[dict(start=0,end=12,label='masks')],[dict(start=8,end=12,label='secret')]]:
            result['spans']=spans
            original=dict(id=row['id'],text=text,gold=row['gold'])
            self.assertEqual(c.evaluate([row],[result],LABELS),literal.evaluate([original],[result],LABELS))
    def test_negative_and_split_masks_count_complete_value(self):
        _,row,result=fixture();result['spans']=[dict(start=8,end=11,label='masks'),dict(start=11,end=14,label='masks')]
        self.assertEqual(c.evaluate([row],[result],LABELS)['fullyCoveredValues'],1)
        row['gold']=[];m=c.evaluate([row],[result],LABELS)
        self.assertEqual(m['negativeExamples'],1);self.assertEqual(m['negativeExamplesWithPrediction'],1)
    def test_wrong_changed_missing_extra_duplicate_identity_refused(self):
        _,row,result=fixture()
        for results in [[],[result,result],[dict(result,id='other')],[dict(result,sourceSHA256='a'*64)]]:
            with self.subTest(results=len(results)),self.assertRaises(ValueError):c.evaluate([row],results,LABELS)
        with self.assertRaises(ValueError):c.evaluate([row,row],[result,result],LABELS)
    def test_invalid_lengths_hashes_and_boolean_bounds_refused(self):
        _,row,result=fixture()
        for change in [dict(textCharacters=True),dict(textCharacters=4097),dict(textCharacters=0),dict(sourceSHA256='bad')]:
            changed=dict(row,**change)
            with self.subTest(change=change),self.assertRaises(ValueError):c.evaluate([changed],[result],LABELS)
        for change in [dict(start=True),dict(start=-1),dict(end=100),dict(end=8)]:
            changed=copy.deepcopy(result);changed['spans'][0].update(change)
            with self.subTest(change=change),self.assertRaises(ValueError):c.evaluate([row],[changed],LABELS)
    def test_unknown_category_nonfinite_boolean_and_out_of_range_scores_refused(self):
        _,row,result=fixture()
        for change in [dict(label='unknown'),dict(label=[]),dict(score=float('nan')),dict(score=float('inf')),dict(score=True),dict(score=-.1),dict(score=1.1)]:
            changed=copy.deepcopy(result);changed['spans'][0].update(change)
            with self.subTest(change=change),self.assertRaises(ValueError):c.evaluate([row],[changed],LABELS)
    def test_bounded_collections_and_no_silent_missing_spans(self):
        _,row,result=fixture()
        for spans in [None,{},[result['spans'][0]]*1001]:
            with self.subTest(spans=type(spans).__name__),self.assertRaises(ValueError):c.evaluate([row],[dict(result,spans=spans)],LABELS)
    def test_alias_duplicates_have_same_set_semantics_as_literal_scorer(self):
        text,row,result=fixture();result['spans']*=2
        self.assertEqual(c.evaluate([row],[result],LABELS),literal.evaluate([dict(id=row['id'],text=text,gold=row['gold'])],[result],LABELS))


if __name__=='__main__':unittest.main()
