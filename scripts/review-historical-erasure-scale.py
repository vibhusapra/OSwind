#!/usr/bin/env python3
"""Independently verify closed authored original-field erasure scale snapshots."""
import argparse,contextlib,hashlib,importlib.util,json,math,pathlib,sqlite3,stat,statistics,uuid

helper=pathlib.Path(__file__).with_name('review-sync-identity-scale.py')
spec=importlib.util.spec_from_file_location('owned_frame_reader',helper);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
def need(value,message):
    if not value:raise ValueError(message)
def sha(data):return hashlib.sha256(data).hexdigest()
def file_sha(path):return sha(path.read_bytes())
def encode(value):return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()
def review(root):
    root=pathlib.Path(root).absolute();need(root.resolve()==root and root.is_dir() and not root.is_symlink(),'Invalid authored root')
    need(stat.S_IMODE(root.stat().st_mode)==0o700 and (root/'owned-fixture').read_bytes()==b'OSwind authored historical erasure scale v1','Missing private authored marker')
    reports=json.loads((root/'report.json').read_text());need([r['count'] for r in reports]==[1000,10000],'Unexpected scale sizes');results=[]
    for report in reports:
        n=report['count'];base=root/('n%d'%n);need(json.loads((base/'report.json').read_text())==report and report['librarySchema']==27,'Schema/report differs')
        snapshots=[]
        for name,path in [('before',base/'before.sqlite'),('after',base/'library/memory.sqlite')]:
            need(path.resolve()==path and path.is_file() and not path.is_symlink(),'Invalid snapshot')
            for suffix in ['-wal','-journal']:
                side=path.with_name(path.name+suffix);need(not side.exists() or side.stat().st_size==0,'Snapshot journal remains')
            digest=file_sha(path);rows={};sources={};logical=0
            with contextlib.closing(sqlite3.connect(path.as_uri()+'?mode=ro&immutable=1',uri=True)) as db:
                need(db.execute('PRAGMA user_version').fetchone()==(27,) and db.execute('PRAGMA quick_check').fetchall()==[('ok',)] and not db.execute('PRAGMA foreign_key_check').fetchall(),'Snapshot integrity differs')
                for table in ['chat_turns','chat_sources','recap_sources','historical_evidence_dependencies','historical_evidence_pins','erasure_assets']:
                    need(db.execute('SELECT count(*) FROM '+table).fetchone()==(0,),'Unexpected authored graph/media state')
                for ident,payload in db.execute('SELECT id,payload FROM memories'):
                    value=json.loads(payload);need(ident=='current-owner' and value['text']=='Independent newer current body' and value['app']=='Keep newer','Newer owner differs');sources[ident]=payload
                need(len(sources)==1,'Newer owner membership differs')
                for handle,owner,obj,content,body,paths,parents,projection in db.execute('SELECT * FROM historical_evidence'):
                    need(str(uuid.UUID(handle))==handle and owner=='current-owner' and paths==b'{}' and parents==b'[]','Original metadata differs')
                    packet=json.loads(body);need(encode(packet)==body and sha(body)==content,'Original body bytes/hash differ')
                    identity=dict(table='memories',origin='00000000-0000-0000-0000-000000005201',lifetime='00000000-0000-0000-0000-000000005202')
                    need(packet['identity']==identity and packet['format']=='OSwind.sync.record' and packet['version']==1,'Original identity differs')
                    need(obj==sha(b'OSwind.sync.object.v1\0source\0'+module.frame(list(identity.values()))),'Original global digest differs')
                    source=packet['body']['source']['_0'];i=int(source['title'].removeprefix('Original '));need(0<=i<n,'Invalid ordinal');target=i%10==0
                    expected=dict(timestamp=1700000000+i-978307200,kind='screen' if i%2==0 else 'note',app='Target original' if target else 'Other original',bundleID='org.owned.target' if target else 'org.owned.other',title='Original %d'%i,url=('https://target.example.test/' if target else 'https://keep.example.test/')+str(i),text='Owned archive source %d '%i+'x'*1024,regions=[],favorite=False,tags=[],media=[])
                    need(source==expected,'Authored original fields differ')
                    native={k:v for k,v in source.items() if k!='media'};native['id']='original-'+handle
                    binding=[handle,owner,obj,content,str(len(body))]
                    need(projection==sha(b'OSwind.historical-evidence.v1\0'+encode(binding)+b'\0'+encode(native)),'Native original projection binding differs')
                    logical+=256+len(body)+len(paths)+len(parents);need(i not in rows,'Duplicate original ordinal');rows[i]=(handle,content,body,projection)
                need(db.execute('SELECT used_bytes FROM historical_evidence_state').fetchone()==(logical,),'Original accounting differs')
                revoked=db.execute('SELECT object_digest,content_sha FROM historical_scope_revoked_versions ORDER BY 1,2').fetchall()
                need(len(revoked)==(0 if name=='before' else n//10),'Original revocation count differs')
                indexes={r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='index' AND name GLOB 'historical_scope_*'")};need(indexes=={'historical_scope_'+k for k in ['start','end','app','bundle','kind','url']},'Scope index membership differs')
                tables=['memories','chat_sessions','chat_turns','chat_sources','recap_sources','routines','routine_runs','memory_entities','entity_aliases','entity_mentions','entity_ignored','entity_project_ignored','text_observation_pins','historical_evidence']
                guards=dict(db.execute("SELECT name,sql FROM sqlite_master WHERE type='trigger' AND name GLOB 'historical_scope_*'"));expected={f'historical_scope_writer_{t}_{op}':f'CREATE TRIGGER historical_scope_writer_{t}_{op} BEFORE {op.upper()} ON {t} BEGIN SELECT oswind_historical_scope_writer_v1(); END' for t in tables for op in ['insert','update','delete']};need(guards==expected,'Writer protection differs')
            need(file_sha(path)==digest,'Readonly review changed snapshot');snapshots.append((rows,sources,digest,revoked))
        before,after=snapshots;need(set(before[0])==set(range(n)) and set(after[0])=={i for i in range(n) if i%10!=0},'Erased/retained version membership differs')
        need(set(after[3])=={(sha(b'OSwind.sync.object.v1\0source\0'+module.frame(['memories','00000000-0000-0000-0000-000000005201','00000000-0000-0000-0000-000000005202'])),v[1]) for i,v in before[0].items() if i%10==0},'Revoked exact versions differ')
        need(before[1]==after[1] and all(before[0][i]==value for i,value in after[0].items()),'Retained owner/version bytes changed')
        timings={};need([x['scope'] for x in report['measurements']]==['app','domain','time','kind'],'Scope coverage differs')
        for entry in report['measurements']:
            scope=entry['scope'];expected={v[0] for i,v in before[0].items() if (i%10==0 if scope in ['app','domain'] else (i>=n-10 if scope=='time' else i%2==0))}
            need(len(entry['selectedHandles'])==len(expected) and set(entry['selectedHandles'])==expected,'Selected handles differ from original fields')
            times=entry['seconds'];need(len(times)==7 and all(type(v) in [float,int] and math.isfinite(v) and v>=0 for v in times),'Invalid preview times');timings[scope]=dict(medianMS=statistics.median(times)*1000,p95MS=max(times)*1000,matches=len(expected),samples=7)
        need(report['deletedOriginals']==n//10 and math.isfinite(report['applySeconds']) and report['applySeconds']>=0,'Invalid apply observation')
        results.append(dict(count=n,allOriginalBodiesBindingsAndSelectionVerified=True,newerOwnerAndRetainedBytesUnchanged=True,beforeSHA256=before[2],afterSHA256=after[2],preview=timings,applyMS=report['applySeconds']*1000))
    return dict(state='reviewed',readerSHA256=file_sha(pathlib.Path(__file__)),frameReaderSHA256=file_sha(helper),inputReportSHA256=file_sha(root/'report.json'),results=results,scope='Closed owned 1KiB originals under one newer owner. Seven warm complete previews and one apply per size. Every typed body, global identity, native binding, selected handle, remaining byte sequence and logical charge independently verified. p95 is nearest-rank of seven samples. Excludes real recording, model/media, cold cache, sustained capture, transport, physical energy and competitor ranking.')
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=pathlib.Path);a=p.parse_args()
    try:print(json.dumps(review(a.root),indent=2,sort_keys=True))
    except (ValueError,OSError,sqlite3.Error,KeyError,TypeError,IndexError) as e:p.exit(1,'Review refused: '+str(e)+'\n')
