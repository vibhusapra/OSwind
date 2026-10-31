#!/usr/bin/env python3
"""Shared admission for pinned, owned sync mutation benchmark outputs."""
import contextlib,hashlib,importlib.util,json,math,pathlib,re,sqlite3
repo=pathlib.Path(__file__).resolve().parents[1]
p=repo/'scripts/review-sync-incoming-routines.py';spec=importlib.util.spec_from_file_location('mutation_native_oracle',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
need=m.need;encode=m.encode;frames=m.frames

def sha(p):
 with pathlib.Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def tree(root):return {str(p.relative_to(root)):sha(p) for p in root.rglob('*') if p.is_file()}
def profile(path):
 path=pathlib.Path(path).absolute();need(path.resolve()==path and not path.is_symlink(),'Invalid profile root');b=json.loads((path/'build.json').read_text());need(b['state']=='built' and b['returncode']==0 and b['inputsUnchanged'],'Successful pinned build required');need(sha(path/'inputs.json')==b['sourceInputsSHA256'],'Compiled manifest pin differs')
 for name,h in json.loads((path/'inputs.json').read_text()).items():
  if name.startswith('.artifacts/'):continue
  q=pathlib.PurePosixPath(name);need(not q.is_absolute() and '..' not in q.parts and str(q)==name,'Invalid compiled input path');need(sha(path/'frozen-inputs'/q)==h,'Frozen source changed')
 need(sha(path/'payload.json')==b['payloadManifestSHA256'],'Payload manifest changed');payload=path/'payload/OSwindPackageTests.xctest';need(not any(p.is_symlink() for p in payload.rglob('*')) and tree(payload)==json.loads((path/'payload.json').read_text()),'Pinned payload changed');need(sha(payload/'Contents/MacOS/OSwindPackageTests')==b['executableSHA256'],'Pinned executable changed');return b

def dataset(root,owner,kind):
 root=pathlib.Path(root).absolute();need(root.resolve()==root and root.is_dir() and not root.is_symlink(),'Invalid dataset root');b=profile(owner);r=json.loads((root/'run.json').read_text());need(r['state']=='completed' and r['returncode']==0 and r['profile']==b['profile'] and r['executableSHA256']==b['executableSHA256'],'Actual successful pinned execution required');need(r['sourceInputsSHA256']==b['sourceInputsSHA256'] and sha(root.parent/'inputs.json')==b['sourceInputsSHA256'],'Execution inputs differ');name='source-projection-regression.log' if kind=='projection' else 'fanout.log';need(r['logName']==name,'Invalid log name');log=root.parent/name;need(sha(log)==r['logSHA256'],'Actual log changed');text=log.read_text();case='testOwnedIncomingRunProjectionAtBoundedScale' if kind=='projection' else 'testOwnedSyncMutationFanoutAtBoundedScale';need(text.count("Test Case '-[OSwindCoreTests.SyncIncomingSourceTests "+case+"]' passed")==1,'Exact executed case required');summaries=re.findall(r'Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures? \((\d+) unexpected\)',text);need(summaries and tuple(int(x or 0) for x in summaries[-1])==(1,0,0,0),'One passing unskipped executed case required');need(sha(root/'report.json')==r['reportSHA256'],'Report pin differs');return b,r

@contextlib.contextmanager
def database(path,pins):
 path=pathlib.Path(path).absolute();need(path.resolve()==path and path.is_file() and not path.is_symlink(),'Invalid database path')
 for suffix in ['-wal','-journal']:
  q=path.with_name(path.name+suffix);need(not q.exists() or q.stat().st_size==0,'Live SQLite journal refused')
 before=sha(path);pins[str(path)]=before
 with contextlib.closing(sqlite3.connect(path.as_uri()+'?mode=ro&immutable=1',uri=True)) as db:
  need(db.execute('PRAGMA user_version').fetchone()==(31,) and db.execute('PRAGMA quick_check').fetchall()==[('ok',)] and db.execute('PRAGMA foreign_key_check').fetchall()==[],'SQLite integrity/schema differs');frames.verify_run_original_schema(db);yield db
 need(sha(path)==before,'Readonly review modified SQLite')

def key(kind,identity):return m.digest(b'OSwind.sync.object.v1\0'+kind.encode()+b'\0'+frames.frame([identity['table'],identity['origin'],identity['lifetime']]))

INDEX_SQL="CREATE INDEX sync_identities_local ON personal_sync_identities(table_name,local_key,object_digest)"
def identity_lookup_plan(db,owner):
 source=(pathlib.Path(owner)/'frozen-inputs/Sources/OSwindCore/SyncIdentityCatalog.swift').read_text()
 expected=INDEX_SQL in source
 actual=db.execute("SELECT sql FROM sqlite_master WHERE name='sync_identities_local'").fetchall()
 need(actual==([(INDEX_SQL,)] if expected else []),'Identity lookup index differs from pinned build')
 plan=[r[3] for r in db.execute("EXPLAIN QUERY PLAN SELECT object_digest FROM personal_sync_identities WHERE table_name='routine_runs' AND local_key=?",(bytes(32),))]
 if expected:need(any('SEARCH personal_sync_identities USING COVERING INDEX sync_identities_local' in p for p in plan) and not any('SCAN personal_sync_identities' in p for p in plan),'Native deletion lookup is not indexed')
 return dict(indexExpected=expected,plan=plan)
