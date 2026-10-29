#!/usr/bin/env python3
import copy
import hashlib
import unittest
import pii_domain_quality as d


def source(value='owned@example.test',kind='email',text=None,uid='owned-1',domain='owned-domain'):
    return dict(uid=uid,domain=domain,document_type='OwnedForm',document_description='Synthetic test only',
                entities=repr([dict(entity=value,types=[kind])]),text=text or 'Field: '+value+'.')


class Tests(unittest.TestCase):
    def test_exact_original_unicode_offsets_and_source_identity(self):
        row=source(text='👩🏽‍💻 Cafe\u0301 email: owned@example.test.');result=d.convert_row(row)
        self.assertEqual(result['gold'],[dict(start=18,end=36,label='email',value='owned@example.test',sourceTypes=['email'])])
        self.assertEqual(result['sourceSHA256'],hashlib.sha256(row['text'].encode()).hexdigest())
    def test_missing_and_repeated_literal_values_refused(self):
        for text in ['No email here.','owned@example.test and owned@example.test']:
            with self.subTest(text=text),self.assertRaises(ValueError):d.convert_row(source(text=text))
    def test_overlapping_repeated_occurrence_refused(self):
        with self.assertRaises(ValueError):d.convert_row(source(value='aa',text='aaa'))
    def test_normalization_and_case_changes_are_not_guessed(self):
        for value,text in [('Cafe\u0301','Café'),('Owned@Example.test','owned@example.test')]:
            with self.subTest(value=value),self.assertRaises(ValueError):d.convert_row(source(value=value,text=text))
    def test_unmapped_annotation_is_explicit_policy_negative(self):
        r=d.convert_row(source(value='Owned Person',kind='name'))
        self.assertEqual(r['gold'],[]);self.assertEqual(r['annotations'][0]['types'],['name'])
    def test_unknown_and_duplicate_entity_types_refused(self):
        for types in [['new_future_type'],['email','email'],[True],[]]:
            r=source();r['entities']=repr([dict(entity='owned@example.test',types=types)])
            with self.subTest(types=types),self.assertRaises(ValueError):d.convert_row(r)
    def test_ambiguous_category_and_overlapping_gold_refused(self):
        r=source();r['entities']=repr([dict(entity='owned@example.test',types=['email','phone_number'])])
        with self.assertRaises(ValueError):d.convert_row(r)
        r=source(value='abcdef');r['entities']=repr([dict(entity='abcdef',types=['email']),dict(entity='bcd',types=['phone_number'])])
        with self.assertRaises(ValueError):d.convert_row(r)
    def test_duplicate_annotation_refused(self):
        r=source();r['entities']=repr([dict(entity='owned@example.test',types=['email'])]*2)
        with self.assertRaises(ValueError):d.convert_row(r)
    def test_malformed_literal_and_executable_expression_refused(self):
        for text in ['[','None','{}',"__import__('builtins').print('must not execute')"]:
            r=source();r['entities']=text
            with self.subTest(text=text),self.assertRaises(ValueError):d.convert_row(r)
    def test_changed_columns_annotation_shape_and_bounds_refused(self):
        changes=[dict(extra='unexpected'),dict(text='x'*4097),dict(uid='../escape'),dict(domain='bad domain'),dict(text='bad\x00source')]
        for change in changes:
            r=source();r.update(change)
            with self.subTest(change=list(change)),self.assertRaises(ValueError):d.convert_row(r)
        r=source();r['entities']=repr([dict(entity='owned@example.test',types=['email'],start=7)])
        with self.assertRaises(ValueError):d.convert_row(r)
    def corpus(self):
        rows=[]
        for kind in sorted(d.POLICY_TYPES):
            for i in range(8):
                rows.append(d.convert_row(source(value=f'Value-{kind}-{i}',kind=kind,uid=f'{kind}-{i}',domain='owned-a' if i%2 else 'owned-b')))
        for i in range(4):rows.append(d.convert_row(source(value=f'Person-{i}',kind='name',uid=f'negative-{i}',domain='owned-a' if i%2 else 'owned-b')))
        return rows
    def test_selection_deterministic_reordered_and_coverage_bounded(self):
        rows=self.corpus();selected=d.select_rows(rows)
        self.assertEqual(selected,d.select_rows(list(reversed(rows))))
        self.assertLessEqual(len(selected),d.MAXIMUM_SELECTED)
        self.assertTrue(all(n>=6 for n in d.describe(selected)['policySourceCountsByPublisherType'].values()))
        self.assertEqual(d.describe(selected)['policyNegativeSources'],2)
    def test_duplicate_source_identity_or_text_refused(self):
        rows=self.corpus()
        with self.assertRaises(ValueError):d.select_rows(rows+[rows[0]])
        other=copy.deepcopy(rows[0]);other['id']='another'
        with self.assertRaises(ValueError):d.select_rows(rows+[other])
    def test_insufficient_type_coverage_refused(self):
        with self.assertRaises(ValueError):d.select_rows([d.convert_row(source())])
    def test_policy_partition_is_complete_and_disjoint(self):
        self.assertEqual(len(d.KNOWN_TYPES),42)
        self.assertFalse(set(d.POLICY_TYPES)&d.EXCLUDED_TYPES)
        self.assertEqual(len(d.POLICY_TYPES),12)


if __name__=='__main__':unittest.main()
