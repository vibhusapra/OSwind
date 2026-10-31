#!/usr/bin/env python3
"""Current CLI erasure of originals in hash-pinned authored actual26 libraries."""
import argparse,contextlib,hashlib,json,pathlib,shutil,sqlite3,subprocess
p=argparse.ArgumentParser();p.add_argument('binary',type=pathlib.Path);p.add_argument('--root',required=True,type=pathlib.Path);a=p.parse_args()
binary=a.binary.resolve();root=a.root.absolute();assert root.resolve()==root and not root.exists() and root.parent.is_dir();root.mkdir(mode=0o700)
repo=pathlib.Path(__file__).resolve().parents[1];folder=repo/'Tests/OSwindCoreTests/Fixtures/HistoricalErasureMigration';meta=json.loads((folder/'provenance.json').read_text());fixture=folder/meta['file'];assert hashlib.sha256(fixture.read_bytes()).hexdigest()==meta['sha256']
report=dict(state='running',binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),harnessSHA256=hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),fixtureSHA256=meta['sha256'],checks=[],scope='Owned actual26 fixture copies, current27 CLI and independent readonly counts. No enrollment, real recording, normal corpus, secure wiping, power or competitor evidence.')
def save(): (root/'report.json').write_text(json.dumps(report,indent=2)+'\n')
def run(library,*args,ok=True):
    r=subprocess.run([str(binary),'--data',str(library),*map(str,args)],capture_output=True,text=True,timeout=60)
    assert (r.returncode==0)==ok,(args,r.stderr)
    return json.loads(r.stdout) if ok else r
try:
    save()
    selectors=[('app',['--app','Safari']),('bundle',['--bundle','com.owned.Safari']),('domain',['--domain','private.example.test']),('kind',['--kind','screen']),('time',['--from','1970-01-01T00:01:30Z','--to','1970-01-01T00:01:50Z'])]
    for name,flags in selectors:
        library=root/name;library.mkdir(mode=0o700);shutil.copy2(fixture,library/'memory.sqlite')
        preview=run(library,'erase','preview',*flags)
        assert preview['sources']==1 and preview['matchedSources']==0 and preview['historicalVersions']==1 and preview['matchedHistoricalVersions']==1 and preview['conversationTurns']==1
        assert preview['historicalSamples'][0]['app']=='Safari' and preview['historicalSamples'][0]['title']=='Old original source'
        result=run(library,'erase','apply',*flags,'--token',preview['token']);assert result['sources']==1 and result['historicalVersions']==1 and result['conversationTurns']==1 and result['pendingMedia']==0
        with contextlib.closing(sqlite3.connect((library/'memory.sqlite').as_uri()+'?mode=ro',uri=True)) as db:
            assert db.execute('PRAGMA user_version').fetchone()==(31,)
            assert db.execute('SELECT id,text FROM memories').fetchall()==[('source','Newer independent current body')]
            assert db.execute('SELECT count(*) FROM historical_evidence').fetchone()==(0,)
            assert db.execute('SELECT count(*) FROM chat_turns').fetchone()==(0,)
            assert not db.execute('PRAGMA foreign_key_check').fetchall()
        report['checks'].append(name);save()
    assert hashlib.sha256(binary.read_bytes()).hexdigest()==report['binarySHA256']
    report.update(state='passed',allChildrenTerminal=True);save();print(json.dumps(report,indent=2))
except BaseException as error:
    report.update(state='failed',errorType=type(error).__name__,error=str(error));save();raise
