#!/usr/bin/env python3
"""Owned single-delete/retention media contracts and optional actual old-writer refusal."""
import argparse,contextlib,hashlib,json,pathlib,shutil,sqlite3,subprocess,tempfile
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary');p.add_argument('--older-binary');p.add_argument('--output');o=p.parse_args();binary=pathlib.Path(o.binary).resolve();older=pathlib.Path(o.older_binary).resolve() if o.older_binary else None;pins={str(b):hashlib.sha256(b.read_bytes()).hexdigest() for b in [binary,older] if b}
@contextlib.contextmanager
def connect(path):
    db=sqlite3.connect(path)
    try:
        with db:yield db
    finally:db.close()

with tempfile.TemporaryDirectory(prefix='oswind-unified-deletion-') as temporary:
    root=pathlib.Path(temporary);library=root/'library'
    def cli(*args,ok=True,runner=binary):
        r=subprocess.run([str(runner),'--data',str(library),*map(str,args)],capture_output=True,text=True,timeout=90)
        assert (r.returncode==0)==ok,(args,r.returncode,r.stdout,r.stderr)
        return json.loads(r.stdout) if r.returncode==0 and r.stdout.lstrip().startswith(('{','[')) else (r.stdout if r.returncode==0 else r.stdout+r.stderr)
    fixture=[('a','1970-01-01T00:01:40Z'),('b','2099-01-01T00:00:00Z'),('c','1970-01-01T00:01:40Z'),('d','2099-01-01T00:00:00Z'),('e','2099-01-01T00:00:00Z')]
    source=root/'input.json';source.write_text(json.dumps([dict(id=i,timestamp=at,kind='screen',app='Owned fixture',bundleID='com.oswind.fixture',title=i,text='owned '+i,favorite=i=='b',tags=[],regions=[]) for i,at in fixture]))
    cli('import',source,runner=older or binary)
    with connect(library/'memory.sqlite') as db:identity=db.execute("SELECT value FROM store_metadata WHERE key='identity'").fetchone()[0]
    assert cli('stats')['count']==5
    with connect(library/'memory.sqlite') as db:
        assert db.execute('PRAGMA user_version').fetchone()[0]==14;assert db.execute("SELECT value FROM store_metadata WHERE key='identity'").fetchone()[0]==identity
    if older:
        before=hashlib.sha256((library/'memory.sqlite').read_bytes()).hexdigest()
        error=cli('delete','b',runner=older,ok=False);assert 'newer' in error.lower()
        assert hashlib.sha256((library/'memory.sqlite').read_bytes()).hexdigest()==before
    for name in ['shared','unique','single']:(library/'images'/name).write_bytes(('owned '+name).encode())
    directory=library/'images/directory';directory.mkdir();(directory/'keep').write_bytes(b'owned directory child')
    with connect(library/'memory.sqlite') as db:
        for identifier,path in [('a','images/shared'),('b','images/./shared'),('c','images/unique'),('d','images/single'),('e','images/directory')]:
            payload=json.loads(db.execute('SELECT payload FROM memories WHERE id=?',(identifier,)).fetchone()[0]);payload['imagePath']=path;db.execute('UPDATE memories SET payload=? WHERE id=?',(json.dumps(payload).encode(),identifier))
    one=cli('delete','a','--json');assert one['sources']==1 and one['sharedMedia']==1 and one['removedMedia']==0 and not one['warnings'];assert (library/'images/shared').read_bytes()==b'owned shared'
    single=cli('delete','d','--json');assert single['sources']==1 and single['removedMedia']==1 and not (library/'images/single').exists()
    for args in [('delete',),('delete','b','--unexpected'),('prune','--days','0'),('prune','--max-gb','bad'),('prune','--days','1','--days','2')]:cli(*args,ok=False)
    retained=cli('prune','--days','1','--json');assert retained['erasure']['sources']==1 and retained['erasure']['removedMedia']==1 and retained['budgetMet'] and retained['erasure']['pendingMedia']==0
    assert cli('get','b')['favorite'] and (library/'images/shared').read_bytes()==b'owned shared' and not (library/'images/unique').exists()
    failed=cli('delete','e','--json');assert failed['sources']==1 and failed['pendingMedia']==1 and failed['warnings'];assert (directory/'keep').read_bytes()==b'owned directory child';cli('get','e',ok=False)
    assert cli('delete','missing','--json')['sources']==0
    shutil.rmtree(directory);assert cli('erase','retry-media')['pendingMedia']==0
    # Direct SQL deletion is still durably staged at the schema boundary; filesystem work is explicit.
    with connect(library/'memory.sqlite') as db:
        db.execute('PRAGMA foreign_keys=ON');db.execute("DELETE FROM memories WHERE id='b'");assert db.execute('SELECT COUNT(*) FROM erasure_assets').fetchone()[0]==1
    assert (library/'images/shared').exists();cleanup=cli('erase','retry-media');assert cleanup['removedMedia']==1 and not (library/'images/shared').exists()
    assert cli('stats')['count']==0
    with connect(library/'memory.sqlite') as db:assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok' and not db.execute('PRAGMA foreign_key_check').fetchall()
assert all(hashlib.sha256(pathlib.Path(b).read_bytes()).hexdigest()==s for b,s in pins.items())
report=dict(format='OSwind unified media deletion process v1',binary_sha256=pins[str(binary)],schema_version=14,single_shared_dot_alias_and_unique_deletion=True,retention_preserves_newer_favorite_shared_bytes=True,postcommit_unsafe_directory_warning_and_retry=True,direct_sql_queue_admission=True,invalid_inputs_preserve_sources=True,sqlite_integrity_pass=True,actual_older_writer=dict(binary_sha256=pins[str(older)],schema13_to14_upgrade_identity_preserved=True,refusal_database_bytes_preserved=True) if older else None,limits=['Owned generated fixture; not secure wipe, crash/power-loss, arbitrary already-open older-writer or natural capture evidence'])
if o.output:pathlib.Path(o.output).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
