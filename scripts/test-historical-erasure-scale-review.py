#!/usr/bin/env python3
"""Corruption controls against copied, independently reviewed owned scale output."""
import argparse,contextlib,copy,importlib.util,json,pathlib,shutil,sqlite3,tempfile
p=argparse.ArgumentParser();p.add_argument('root',type=pathlib.Path);a=p.parse_args()
reader=pathlib.Path(__file__).with_name('review-historical-erasure-scale.py');spec=importlib.util.spec_from_file_location('owned_scope_reader',reader);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
original=m.review(a.root);checks=[]
with tempfile.TemporaryDirectory(prefix='oswind-scope-oracle-') as temporary:
    root=pathlib.Path(temporary).resolve()/'owned';shutil.copytree(a.root,root)
    reports=json.loads((root/'report.json').read_text());per=root/'n1000/report.json'
    def write(value):
        (root/'report.json').write_text(json.dumps(value));per.write_text(json.dumps(value[0]))
    def refuses(name):
        try:m.review(root)
        except (ValueError,OSError,sqlite3.Error,KeyError,TypeError,IndexError):checks.append(name)
        else:raise AssertionError('Corruption admitted: '+name)
    changed=copy.deepcopy(reports);changed[0]['measurements'][0]['selectedHandles'][0]='00000000-0000-0000-0000-000000000000';write(changed);refuses('forged selected original handle');write(reports)
    changed=copy.deepcopy(reports);changed[0]['measurements'][0]['seconds'][0]=float('nan');write(changed);refuses('nonfinite timer');write(reports)
    changed=copy.deepcopy(reports);changed[0]['librarySchema']=28;write(changed);refuses('unqualified future schema');write(reports)
    marker=root/'owned-fixture';marker.write_bytes(b'normal history');refuses('unmarked library');marker.write_bytes(b'OSwind authored historical erasure scale v1')
    db=root/'n1000/before.sqlite';saved=pathlib.Path(temporary).resolve()/'saved.sqlite';shutil.copy2(db,saved)
    with contextlib.closing(sqlite3.connect(db)) as connection:
        connection.execute('DROP TRIGGER historical_scope_writer_memories_delete');connection.commit()
    refuses('missing writer protection');shutil.copy2(saved,db)
    with contextlib.closing(sqlite3.connect(db)) as connection:
        connection.create_function('oswind_historical_writer_v1',0,lambda:1);connection.create_function('oswind_historical_scope_writer_v1',0,lambda:1)
        connection.execute('DROP TRIGGER historical_immutable')
        row=connection.execute('SELECT handle,body FROM historical_evidence LIMIT 1').fetchone();body=row[1].replace(b'Owned archive source',b'Wrong archive source');assert body!=row[1]
        connection.execute('UPDATE historical_evidence SET body=? WHERE handle=?',(body,row[0]));connection.commit()
    refuses('valid JSON original body with stale exact hash');shutil.copy2(saved,db)
    assert m.review(root)['results']==original['results']
print(json.dumps(dict(state='passed',controls=checks,originalFixturesUnchanged=m.review(a.root)['results']==original['results']),indent=2))
