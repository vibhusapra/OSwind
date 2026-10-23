#!/usr/bin/env python3
"""Back up/restore an existing OSwind synthetic vector benchmark fixture.

Refuses roots without the explicit synthetic-fixture marker. Never copies native
cache/model files. Preserves raw operation logs and partial/failure reports.
"""
import argparse, json, pathlib, re, sqlite3, subprocess, tempfile, time
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary')
parser.add_argument('--archive',required=True)
parser.add_argument('--output',required=True)
args=parser.parse_args(); binary=pathlib.Path(args.binary).resolve(); source=pathlib.Path(args.archive).resolve(); output=pathlib.Path(args.output)
marker=json.loads((source/'benchmark-fixture.json').read_text())
assert marker['kind']=='OSwind synthetic vectors v1' and 1<=marker['count']<=1000000 and 1<=marker['dimensions']<=8192
report={'fixture':marker,'revision':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'limits':['single operation trial per phase','uncontrolled APFS/cache state','synthetic vectors/text; no retained media or chats','includes SQLite data/derived SQL tables; excludes disposable native graph files','not battery or competitor evidence']}
with tempfile.TemporaryDirectory(prefix='oswind-backup-vectors-') as directory:
    archive=pathlib.Path(directory)/'package.oswindbackup'; restored=pathlib.Path(directory)/'restored'
    def measured(name,arguments):
        started=time.monotonic()
        result=subprocess.run(['/usr/bin/time','-l',str(binary),'--data',str(source),*map(str,arguments)],capture_output=True,text=True,timeout=3600)
        elapsed=time.monotonic()-started; output.with_suffix('.'+name+'.log').write_text(result.stderr)
        rss=re.search(r'^\s*(\d+)\s+maximum resident set size',result.stderr,re.M)
        measurement={'seconds':elapsed,'peak_rss_bytes':int(rss[1]) if rss else None,'exit_code':result.returncode}
        if result.returncode==0: measurement['result']=json.loads(result.stdout)
        else: measurement['error_tail']=result.stderr.splitlines()[-30:]
        report[name]=measurement; output.write_text(json.dumps(report,indent=2)+'\n')
        assert result.returncode==0,(name,result.returncode,result.stderr[-5000:])
        return measurement['result']
    created=measured('create',['backup','create',archive]); checked=measured('inspect',['backup','inspect',archive])
    rebuilt=measured('restore',['backup','restore',archive,'--to',restored,'--fingerprint',created['archiveFingerprint']])
    assert created==checked==rebuilt and rebuilt['memories']==marker['count'] and rebuilt['mediaFiles']==0
    # Compare ordered data rows in bounded batches, not archive-sized lists.
    original=sqlite3.connect('file:'+str(source/'memory.sqlite')+'?mode=ro',uri=True)
    target=sqlite3.connect('file:'+str(restored/'memory.sqlite')+'?mode=ro',uri=True)
    try:
        for table,columns,order in [('memories','id,timestamp,kind,app,title,url,text,favorite,payload,embedding,embedding_model','id'),('semantic_vectors','memory_id,model,dimension,vector,content_hash','memory_id,model')]:
            a=original.execute(f'SELECT {columns} FROM {table} ORDER BY {order}'); b=target.execute(f'SELECT {columns} FROM {table} ORDER BY {order}'); count=0
            while True:
                left=a.fetchmany(64); right=b.fetchmany(64)
                # Payload encoding key order can change on restore. Compare its JSON value.
                if table=='memories':
                    left=[(*row[:8],json.loads(row[8]),*row[9:]) for row in left]; right=[(*row[:8],json.loads(row[8]),*row[9:]) for row in right]
                assert left==right,(table,count)
                count+=len(left)
                if not left: break
            report[table+'_rows_verified']=count
        assert target.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
        assert target.execute('PRAGMA foreign_key_check').fetchall()==[]
    finally: original.close(); target.close()
    report['passed']=True; output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
