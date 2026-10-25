"""Evaluate an explicitly pinned CLI against an already frozen offline selection.

Uses fresh local libraries and default source privacy. It refuses changed source
text rather than silently discarding or relabeling corpus examples. The evaluator
does not download, contact a provider, capture the desktop or open normal history.
"""
import argparse,contextlib,hashlib,json,pathlib,sqlite3,subprocess,time
from entity_quality import score,gold_memberships

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def evaluate(args):
 cli=args.binary.resolve();planPath=args.plan.resolve();plan=json.loads(planPath.read_text());dataRoot=planPath.parent
 if sha(cli)!=args.binary_sha256 or sha(planPath)!=args.plan_sha256:raise ValueError('Frozen binary/protocol differs')
 if sha(pathlib.Path(__file__).with_name('entity_quality.py'))!=plan['scorerSHA256']:raise ValueError('Frozen scorer differs')
 source=dataRoot/(args.split+'-selected.json');spec=plan['files'][args.split]
 if sha(source)!=spec['selectedSHA256']:raise ValueError('Frozen selected records differ')
 records=json.loads(source.read_text());assert len(records)==spec['selectedRows']
 output=args.output.resolve();output.mkdir(mode=0o700,parents=True,exist_ok=False);library=output/'library'
 expected={r['id']:gold_memberships(r)[0] for r in records};memories=[dict(id=r['id'],timestamp='2026-10-25T00:00:00Z',kind='note',app='Few-NERD entity evaluation',bundleID='org.oswind.owned-entity-evaluation',title='Independent entity source',text=expected[r['id']],regions=[],tags=[],favorite=False) for r in records]
 inputPath=output/'input.json';inputPath.write_text(json.dumps(memories,ensure_ascii=False))
 report=dict(format='OSwind independent entity membership evaluation v1',state='started',binarySHA256=sha(cli),planSHA256=sha(planPath),selectionSHA256=sha(source),scorerSHA256=plan['scorerSHA256'],evaluatorSHA256=sha(pathlib.Path(__file__)),split=args.split,sources=len(records),operations=[],scope='Fresh actual CLI import/index library on pinned public Few-NERD projection. Default source privacy; exact text equivalence required. No normal history, capture, provider, downloads, token-level NER or competitor claim.')
 reportPath=output/'report.json'
 def persist():reportPath.write_text(json.dumps(report,indent=2)+'\n')
 def run(name,*command):
  start=time.monotonic();r=subprocess.run([str(cli),'--data',str(library),*map(str,command)],capture_output=True,text=True,timeout=300)
  (output/(name+'.stdout')).write_text(r.stdout);(output/(name+'.stderr')).write_text(r.stderr)
  report['operations'].append(dict(name=name,exitCode=r.returncode,wallSeconds=time.monotonic()-start,stdoutSHA256=sha(output/(name+'.stdout')),stderrSHA256=sha(output/(name+'.stderr'))));persist()
  if r.returncode:raise ValueError('Actual CLI operation failed: '+name)
  return json.loads(r.stdout)
 persist()
 try:
  imported=run('import','import',inputPath,'--json')
  if imported['imported']!=len(records):raise ValueError('Not all selected records admitted')
  database=library/'memory.sqlite'
  with contextlib.closing(sqlite3.connect(database.as_uri()+'?mode=ro',uri=True)) as db:
   actual=dict(db.execute('SELECT id,text FROM memories'));report['schema']=db.execute('PRAGMA user_version').fetchone()[0]
  changed=[i for i,text in expected.items() if actual.get(i)!=text]
  report['sourceTextMismatches']=changed;persist()
  if changed:raise ValueError('Default import changed corpus text; preserve report and freeze an explicitly revised protocol before proceeding')
  progress=run('index','entity','index');report['indexProgress']=progress
  if progress['indexed']!=len(records) or progress['eligible']!=len(records):raise ValueError('Not all selected records indexed')
  with contextlib.closing(sqlite3.connect(database.as_uri()+'?mode=ro',uri=True)) as db:
   if db.execute('SELECT COUNT(*) FROM memory_entities WHERE curated<>0 OR kind=\'project\'').fetchone()[0]:raise ValueError('Unexpected deliberate/project definition in isolated evaluation')
   rows=list(db.execute('SELECT m.memory_id,e.kind,m.surface,m.start,m.length,m.origin,m.method FROM entity_mentions m JOIN memory_entities e ON e.id=m.entity_id ORDER BY m.memory_id,e.kind,m.start'))
  if any(origin!='automatic' or method!='apple-nameType' for _,_,_,_,_,origin,method in rows):raise ValueError('Unexpected extraction method/origin')
  predictions=[dict(source=i,kind=k,surface=s,start=a,length=n) for i,k,s,a,n,_,_ in rows]
  predictionsPath=output/'predictions.json';predictionsPath.write_text(json.dumps(predictions,ensure_ascii=False,indent=2)+'\n')
  report['predictionsSHA256']=sha(predictionsPath);report['metrics']=score(records,predictions);report['state']='completed';persist();print(json.dumps(report,indent=2))
 except BaseException as error:
  report['state']='failed';report['failureType']=type(error).__name__;persist();raise

if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',required=True,type=pathlib.Path);p.add_argument('--binary-sha256',required=True);p.add_argument('--plan',required=True,type=pathlib.Path);p.add_argument('--plan-sha256',required=True);p.add_argument('--split',required=True,choices=['validation','test']);p.add_argument('--output',required=True,type=pathlib.Path);evaluate(p.parse_args())
