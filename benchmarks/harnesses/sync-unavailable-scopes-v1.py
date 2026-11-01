from pathlib import Path
import subprocess,sys,os,json,sqlite3,contextlib,time,hashlib,re,datetime,struct,importlib.util,argparse,platform

parser=argparse.ArgumentParser(description='Authored schema32 native unavailable-scope retirement; no source ingestion, models, capture, network or competitive ranking.')
parser.add_argument('--cli',type=Path);parser.add_argument('--output',type=Path);parser.add_argument('--source');parser.add_argument('--cli-sha256');args=parser.parse_args()
repo=Path.cwd();base=repo/'.artifacts/sync-unavailable-scopes-v1';qual=base/'qualification-v3'
if args.cli is None:
    assert args.output is None and args.source is None and args.cli_sha256 is None
    receipt=json.loads((qual/'result.json').read_text());assert receipt['state']=='passed'
    cli=qual/'OSwind.app/Contents/MacOS/oswindctl';source=receipt['source'];assert source.startswith('36a0e66');root=base/'performance-v1';expectedBinary=receipt['cliSHA256'];association='Exact source-qualified staged binary and qualification receipt'
else:
    assert args.output and args.source and args.cli_sha256 and re.fullmatch('[0-9a-f]{40}',args.source) and re.fullmatch('[0-9a-f]{64}',args.cli_sha256)
    cli=args.cli.resolve();root=args.output.absolute();source=args.source;expectedBinary=args.cli_sha256;association='Caller-declared source and caller-pinned binary; this standalone mode does not certify their build association'
assert root.resolve()==root and root.parent.is_dir() and not root.exists() and cli.is_file();root.mkdir(mode=0o700)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
assert sha(cli)==expectedBinary
spec=importlib.util.spec_from_file_location('owned_scope_fixture',repo/'scripts/owned_sqlite_fixture.py');fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)
def encode(x):return json.dumps(x,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()
def command(library,*args):
    value=subprocess.run([str(cli),'--data',str(library),*map(str,args)],capture_output=True,text=True,timeout=120);assert value.returncode==0,value.stderr
    if args[0]=='note':return value.stdout.strip()
    return json.loads(value.stdout) if value.stdout.strip() else None
def snapshot(library):
    with contextlib.closing(sqlite3.connect((library/'memory.sqlite').as_uri()+'?mode=ro',uri=True)) as db:
        return {table:db.execute('SELECT * FROM '+table+' ORDER BY id').fetchall() for table in ['chat_turns','routine_runs','memories']}
def typed_hash(rows):
    h=hashlib.sha256()
    for row in rows:
        for value in row:
            if value is None:data=b'n'
            elif isinstance(value,bytes):data=b'b'+value
            elif isinstance(value,str):data=b's'+value.encode()
            elif isinstance(value,float):data=b'f'+struct.pack('>d',value)
            elif isinstance(value,int):data=b'i'+struct.pack('>q',value)
            else:raise AssertionError(type(value))
            h.update(struct.pack('>Q',len(data))+data)
    return h.hexdigest()
report=dict(state='running',source=source,buildAssociation=association,cliSHA256=sha(cli),driverSHA256=sha(Path(__file__)),startedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),observations=[],scope='One warm owned native CLI entity deletion per size, with N scoped turns plus N stored-run filters and unaffected controls. Timer includes CLI startup, schema checks, exact native scope retirement and process exit. Population is authored raw SQLite with inactive capture and current default-deny fixture registration, not API ingestion. Setup/source-control creation including its ordinary local embedding is outside the measured interval. No imported run originals, journal/transport, timed model inference, capture, energy, causal comparison or competitive ranking.')
report['host']=dict(architecture=platform.machine(),cpu=subprocess.check_output(['/usr/sbin/sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),memoryBytes=int(subprocess.check_output(['/usr/sbin/sysctl','-n','hw.memsize'],text=True)),macOS=subprocess.check_output(['/usr/bin/sw_vers','-productVersion'],text=True).strip(),swift=subprocess.check_output(['swift','--version'],text=True).strip())
def save():(root/'report.json').write_text(json.dumps(report,indent=2)+'\n')
save()
try:
    for n in [1000,10000]:
        folder=root/('n'+str(n));folder.mkdir();library=folder/'library';command(library,'stats')
        entity=command(library,'entity','create','project','Owned performance scope')['id'];other=command(library,'entity','create','project','Owned unaffected scope')['id']
        definition=command(library,'routine','template');definition['id']='owned-scope-performance';path=folder/'recipe.json';path.write_bytes(encode(definition));command(library,'routine','put',path)
        command(library,'note','Unrelated authored source remains exact')
        started=time.monotonic()
        with contextlib.closing(sqlite3.connect(library/'memory.sqlite')) as db:
            fixture.register_inactive_sync_fixture(db);db.execute('PRAGMA foreign_keys=ON');db.execute('PRAGMA recursive_triggers=ON')
            db.execute("INSERT INTO chat_sessions VALUES('owned-scope-chat','Owned performance history',1700000000,1700000000)")
            for i in range(n+1):
                active=other if i==n else entity;scope=dict(query='',app='Owned',favoritesOnly=False,limit=100,entityID=active)
                payload=dict(question=f'Exact original question {i} e\u0301 👩🏽‍💻',text=f'Exact original answer {i} 👩🏽‍💻 e\u0301',provider='owned',duration=1.25,warnings=['Owned exact warning'],filter=scope,timeZone='UTC')
                db.execute('INSERT INTO chat_turns VALUES(?,?,?,?)',(f'owned-turn-{i:06d}','owned-scope-chat',1700000000.25+i,encode(payload)))
                db.execute('INSERT INTO routine_runs VALUES(?,?,?,?,?,?,?,?,?,?,?)',(f'owned-run-{i:06d}',definition['id'],1,1700000000.25+i,1700000001.25+i,1700000002.25+i,'manual','failed','owned-scope-chat',f'Exact original message {i} e\u0301',encode(scope)))
            for table in ['chat_turns','routine_runs']:db.execute('UPDATE '+table+' SET rowid=-9223372036854775808 WHERE rowid=(SELECT min(rowid) FROM '+table+')')
            db.commit()
        population=time.monotonic()-started;before=snapshot(library)
        (folder/'before-hashes.json').write_text(json.dumps({table:typed_hash(rows) for table,rows in before.items()},indent=2)+'\n')
        output=folder/'deletion.stdout';error=folder/'deletion.stderr';started=time.monotonic()
        with output.open('wb') as out,error.open('wb') as err:
            result=subprocess.run(['/usr/bin/time','-lp',str(cli),'--data',str(library),'entity','delete',entity],stdout=out,stderr=err,timeout=300)
        elapsed=time.monotonic()-started;assert result.returncode==0,error.read_text();assert json.loads(output.read_text())=={'deleted':True};after=snapshot(library)
        assert before['memories']==after['memories']
        for table,cell in [('chat_turns',3),('routine_runs',10)]:
            assert len(before[table])==len(after[table])==n+1
            for old,new in zip(before[table],after[table]):
                assert old[:cell]==new[:cell] and old[cell+1:]==new[cell+1:]
                original=json.loads(old[cell]);updated=json.loads(new[cell]);prior=original['filter'] if table=='chat_turns' else original;current=updated['filter'] if table=='chat_turns' else updated
                if prior['entityID']==other:assert old==new
                else:
                    assert prior['entityID']==entity and current.pop('entityID')=={'state':'unavailable'} and current.pop('unavailableEntityScope')=={}
                    current['entityID']=entity;assert encode(updated)==encode(original)
        with contextlib.closing(sqlite3.connect((library/'memory.sqlite').as_uri()+'?mode=ro',uri=True)) as db:
            assert db.execute('PRAGMA user_version').fetchone()==(32,);assert db.execute('PRAGMA quick_check').fetchall()==[('ok',)];assert not db.execute('PRAGMA foreign_key_check').fetchall()
            assert db.execute('SELECT id FROM memory_entities ORDER BY id').fetchall()==[(other,)]
            assert db.execute('SELECT enabled,suppressed,used_bytes FROM personal_sync_capture').fetchall()==[(0,0,0)]
            assert db.execute('SELECT count(*) FROM routine_run_originals').fetchone()==(0,)
        times=error.read_text();rss=re.search(r'(\d+)\s+maximum resident set size',times);assert rss,times
        observation=dict(rowsPerHistory=n,retiredFilters=2*n,unaffectedControls=2,populationSeconds=population,wholeCLIWallSeconds=elapsed,wholeProcessPeakRSSBytes=int(rss.group(1)),fullNativeRowOraclePassed=True,originalSourceUnchanged=True,sqliteIntegrityPassed=True,minimumNegativeRowIDIncluded=True,beforeTypedSHA256={table:typed_hash(rows) for table,rows in before.items()},afterTypedSHA256={table:typed_hash(rows) for table,rows in after.items()},stdoutSHA256=sha(output),stderrSHA256=sha(error))
        report['observations'].append(observation);save();print('PASS',n,round(elapsed,4),flush=True)
    assert sha(cli)==report['cliSHA256'];report['state']='passed';save()
except BaseException as e:report.update(state='failed',error=str(e));save();raise
finally:report['finishedAtUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat();save()
