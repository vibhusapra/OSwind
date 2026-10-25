#!/usr/bin/env python3
"""Offline independent scoring and evaluator-admission tests on authored data."""
import hashlib,json,pathlib,subprocess,sys,tempfile,unittest
from entity_quality import score,gold_memberships,select

HERE=pathlib.Path(__file__).resolve().parent
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def record(identifier='owned'):
 return dict(id=identifier,tokens=['😀','Maya','Chen','met','Maya','Chen','in','Paris','.'],ner_tags=[0,7,7,0,7,7,0,4,0],fine_ner_tags=[0,54,54,0,54,54,0,21,0])

class IndependentScoreTests(unittest.TestCase):
 def test_repeated_membership_has_one_denominator_and_any_exact_anchor(self):
  r=record();p=[dict(source='owned',kind='person',surface='Maya Chen',start=17,length=9),dict(source='owned',kind='place',surface='Paris',start=30,length=5)]
  m=score([r],p);self.assertEqual(m['membership']['micro']['truePositive'],2);self.assertEqual(m['anchoredMembership']['micro']['F1'],1)
 def test_partial_name_is_both_false_positive_and_false_negative(self):
  m=score([record()],[dict(source='owned',kind='person',surface='Chen',start=8,length=4)])['membership']['micro'];self.assertEqual((m['truePositive'],m['falsePositive'],m['falseNegative']),(0,1,2))
 def test_correct_name_with_surrogate_split_is_unanchored(self):
  m=score([record()],[dict(source='owned',kind='person',surface='Maya Chen',start=1,length=9)]);self.assertEqual(m['membership']['micro']['truePositive'],1);self.assertEqual(m['invalidSourceAnchors'],1);self.assertEqual(m['anchoredMembership']['micro']['truePositive'],0)
 def test_negative_source_predictions_are_false_positives(self):
  r=dict(id='negative',tokens=['Clear','weather'],ner_tags=[0,0],fine_ner_tags=[0,0]);m=score([r],[dict(source='negative',kind='person',surface='Clear',start=0,length=5)]);self.assertEqual(m['membership']['micro']['falsePositive'],1)
 def test_missing_predictions_count_all_gold_memberships(self):
  self.assertEqual(score([record()],[])['membership']['micro']['falseNegative'],2)
 def test_adjacent_fine_types_do_not_merge_under_coarse_projection(self):
  r=dict(id='adjacent',tokens=['Harbor','Tower'],ner_tags=[4,2],fine_ner_tags=[21,11]);self.assertEqual(len(gold_memberships(r)[1]),2)
 def test_unknown_source_duplicate_membership_and_duplicate_source_refuse(self):
  p=dict(source='owned',kind='person',surface='Maya Chen',start=3,length=9)
  for rows,pred in [([record()],[dict(p,source='unknown')]),([record()],[p,p]),([record(),record()],[])]:
   with self.subTest(rows=len(rows),pred=len(pred)),self.assertRaises(ValueError):score(rows,pred)
 def test_selection_is_order_independent_and_rejects_duplicate_ids(self):
  records=[record('a'),record('b'),record('c')];self.assertEqual(select(records,'test',2),select(list(reversed(records)),'test',2))
  with self.assertRaises(ValueError):select([record(),record()],'test',1)

class ActualEvaluatorBoundaryTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(prefix='oswind-entity-score-test-');self.root=pathlib.Path(self.temp.name)
  self.selected=self.root/'test-selected.json';self.selected.write_text(json.dumps([record()]))
  self.plan=self.root/'plan.json';self.plan.write_text(json.dumps(dict(scorerSHA256=digest(HERE/'entity_quality.py'),files=dict(test=dict(selectedSHA256=digest(self.selected),selectedRows=1)))))
 def tearDown(self):self.temp.cleanup()
 def binary(self,mutate=False):
  path=self.root/'owned-cli';program='''import pathlib,sys,json,sqlite3
root=pathlib.Path(sys.argv[2]);root.mkdir(parents=True,exist_ok=True);db=sqlite3.connect(root/'memory.sqlite');action=sys.argv[3]
if action=='import':
 rows=json.loads(pathlib.Path(sys.argv[4]).read_text());db.execute('CREATE TABLE memories(id TEXT,text TEXT)')
 for row in rows:db.execute('INSERT INTO memories VALUES(?,?)',(row['id'],row['text']+MUTATION))
 db.commit();print(json.dumps(dict(imported=len(rows))))
elif action=='entity':
 db.executescript("CREATE TABLE memory_entities(id TEXT,kind TEXT,curated INTEGER);CREATE TABLE entity_mentions(memory_id TEXT,entity_id TEXT,surface TEXT,start INTEGER,length INTEGER,origin TEXT,method TEXT);")
 db.execute("INSERT INTO memory_entities VALUES('person','person',0)");db.execute("INSERT INTO entity_mentions VALUES('owned','person','Maya Chen',17,9,'automatic','apple-nameType')");db.commit();print(json.dumps(dict(indexed=1,eligible=1,limited=0)))
db.close()
'''.replace('MUTATION',repr(' changed' if mutate else ''))
  path.write_text('#!'+sys.executable+'\n'+program);path.chmod(0o700);return path
 def invoke(self,binary,**overrides):
  options=dict(binary=str(binary),binary_sha256=digest(binary),plan=str(self.plan),plan_sha256=digest(self.plan),split='test',output=str(self.root/'result'));options.update(overrides)
  args=[sys.executable,str(HERE/'entity_corpus_eval.py')]
  for key,value in options.items():args.extend(['--'+key.replace('_','-'),value])
  return subprocess.run(args,capture_output=True,text=True,timeout=20)
 def test_actual_process_scores_missing_place_as_false_negative(self):
  p=self.invoke(self.binary());self.assertEqual(p.returncode,0,p.stderr);r=json.loads((self.root/'result/report.json').read_text());self.assertEqual(r['state'],'completed');self.assertEqual(r['metrics']['membership']['micro']['falseNegative'],1);self.assertEqual(r['metrics']['anchoredMembership']['micro']['truePositive'],1)
 def test_import_privacy_change_refuses_scoring_and_retains_failed_receipt(self):
  p=self.invoke(self.binary(mutate=True));self.assertNotEqual(p.returncode,0);r=json.loads((self.root/'result/report.json').read_text());self.assertEqual(r['state'],'failed');self.assertEqual(r['sourceTextMismatches'],['owned']);self.assertNotIn('metrics',r);self.assertEqual([x['name'] for x in r['operations']],['import'])
 def test_binary_and_protocol_changes_refuse_before_creating_result(self):
  binary=self.binary()
  for change in [dict(binary_sha256='0'*64),dict(plan_sha256='0'*64)]:
   p=self.invoke(binary,**change);self.assertNotEqual(p.returncode,0);self.assertFalse((self.root/'result').exists())
 def test_selection_change_refuses_before_creating_result(self):
  binary=self.binary();self.selected.write_text('[]');p=self.invoke(binary);self.assertNotEqual(p.returncode,0);self.assertFalse((self.root/'result').exists())

if __name__=='__main__':unittest.main()
