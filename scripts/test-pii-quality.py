#!/usr/bin/env python3
import hashlib,importlib.util,pathlib,unittest,json,tempfile
HERE=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('pii_quality',HERE/'pii_quality.py');q=importlib.util.module_from_spec(spec);spec.loader.exec_module(q)
def result(id,text,spans):return {'id':id,'sourceSHA256':hashlib.sha256(text.encode()).hexdigest(),'spans':spans}
class Tests(unittest.TestCase):
 def setUp(self):
  self.text='🔒 e\u0301: owned@example.test';self.start=self.text.index('owned');self.end=len(self.text);self.gold={'start':self.start,'end':self.end,'label':'email'};self.rows=[{'id':'owned','text':self.text,'gold':[self.gold]}]
 def test_exact_match_and_utf16(self):
  r=q.evaluate(self.rows,[result('owned',self.text,[self.gold])],['email']);self.assertEqual(r['exactTypedSpans']['f1'],1);self.assertEqual(r['fullValueRecall'],1);self.assertEqual(q.utf16_range(self.text,self.start,self.end),{'location':7,'length':18})
 def test_partial_mask_does_not_count_complete_value(self):
  p=dict(self.gold,end=self.end-1);r=q.evaluate(self.rows,[result('owned',self.text,[p])],['email']);self.assertEqual(r['fullValueRecall'],0);self.assertEqual(r['exactTypedSpans']['tp'],0);self.assertGreater(r['characterCoverageUntyped']['recall'],0)
 def test_negative_false_positive_is_counted(self):
  rows=[{'id':'owned','text':self.text,'gold':[]}];r=q.evaluate(rows,[result('owned',self.text,[self.gold])],['email']);self.assertEqual(r['negativeFalsePositiveRate'],1)
 def test_missing_extra_duplicate_and_changed_sources_refused(self):
  for values in [[],[result('other',self.text,[])],[result('owned','changed',[])],[result('owned',self.text,[])]*2]:
   with self.subTest(values=values),self.assertRaises(ValueError):q.evaluate(self.rows,values,['email'])
 def test_invalid_offsets_labels_text_and_scores_refused(self):
  for change in [{'start':True},{'start':-1},{'end':1000},{'end':self.start},{'label':'invented'},{'text':'not source'},{'score':float('nan')},{'score':1.1}]:
   p=dict(self.gold,**change)
   with self.subTest(change=change),self.assertRaises(ValueError):q.evaluate(self.rows,[result('owned',self.text,[p])],['email'])
 def test_wrong_type_is_not_exact_but_preserves_untyped_coverage(self):
  p=dict(self.gold,label='secret');r=q.evaluate(self.rows,[result('owned',self.text,[p])],['email','secret']);self.assertEqual(r['exactTypedSpans']['tp'],0);self.assertEqual(r['characterCoverageUntyped']['f1'],1)
 def test_duplicates_do_not_inflate_counts(self):
  r=q.evaluate(self.rows,[result('owned',self.text,[self.gold,self.gold])],['email']);self.assertEqual(r['exactTypedSpans']['tp'],1)
 def test_baseline_mask_preserves_original_offsets(self):
  self.assertEqual(q.legacy_mask('🔒 secret done','🔒 [REDACTED] done'),[{'start':2,'end':8,'label':'pattern_redaction'}])
  self.assertEqual(q.legacy_mask('literal [REDACTED]','literal [REDACTED]'),[])
  self.assertEqual(q.legacy_mask('abcd','[REDACTED][REDACTED]'),[{'start':0,'end':4,'label':'pattern_redaction'}])
 def test_ambiguous_baseline_mask_is_refused(self):
  with self.assertRaises(ValueError):q.legacy_mask('a x a x a','[REDACTED] x [REDACTED]')
 def test_same_count_duplicate_results_refused(self):
  rows=self.rows+[dict(self.rows[0],id='second')]
  with self.assertRaises(ValueError):q.evaluate(rows,[result('owned',self.text,[]),result('owned',self.text,[])],['email'])
 def test_invalid_unicode_scalar_refused(self):
  text='\ud800';rows=[{'id':'owned','text':text,'gold':[{'start':0,'end':1,'label':'email'}]}]
  with self.assertRaises(UnicodeEncodeError):q.evaluate(rows,[{'id':'owned','sourceSHA256':'bad','spans':[]}],['email'])
 def test_overlong_source_refused_before_expanding_character_sets(self):
  text='a'*4097
  with self.assertRaises(ValueError):q.evaluate([{'id':'owned','text':text,'gold':[]}],[result('owned',text,[])],['email'])
 def test_plan_binds_code_and_corpus_and_refuses_path_escape(self):
  with tempfile.TemporaryDirectory() as folder:
   root=pathlib.Path(folder);(root/'scripts').mkdir();entries={}
   for name in ['prepare-pii-eval.py','pii_quality.py','test-pii-quality.py','evaluate-pii-model.py','evaluate-pii-baseline.py']:
    path=root/'scripts'/name;path.write_text(name);entries['scripts/'+name]=q.sha256(path)
   corpus=root/'corpus.json';corpus.write_text('owned corpus');path=root/'plan.json';plan={'codeSHA256':entries,'corpusSHA256':q.sha256(corpus)}
   def save():path.write_text(json.dumps(plan))
   save();self.assertEqual(q.verify_plan(path,corpus,root),plan)
   corpus.write_text('changed corpus')
   with self.assertRaisesRegex(ValueError,'corpus differs'):q.verify_plan(path,corpus,root)
   corpus.write_text('owned corpus');(root/'scripts/pii_quality.py').write_text('changed code')
   with self.assertRaisesRegex(ValueError,'code differs'):q.verify_plan(path,corpus,root)
   (root/'scripts/pii_quality.py').write_text('pii_quality.py');entries['../escape']='bad';save()
   with self.assertRaisesRegex(ValueError,'escapes checkout'):q.verify_plan(path,corpus,root)
 def test_corpus_contract_has_complete_exact_source_spans_and_no_split_overlap(self):
  spec=importlib.util.spec_from_file_location('pii_corpus',HERE/'prepare-pii-eval.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);rows=module.build()
  self.assertEqual(len(rows),216);self.assertEqual(sum(r['split']=='validation' for r in rows),72)
  self.assertEqual(len({r['text'] for r in rows}),216)
  for row in rows:
   for span in row['gold']:
    q.validate_span(row['text'],span,set(module.LABELS.values()));self.assertEqual(row['text'][span['start']:span['end']],span['value'])
if __name__=='__main__':unittest.main()
