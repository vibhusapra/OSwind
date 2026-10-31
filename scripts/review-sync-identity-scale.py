#!/usr/bin/env python3
"""Independently inspect a completed marked authored identity-scale fixture.

Does not import the Swift fixture or catalog. Opens only a journal-free authored
archive read-only, checks actual source cells and all object/key mappings, then
recomputes batch summaries. Not a live-library or whole-sync qualification.
"""
import argparse,hashlib,json,math,pathlib,re,sqlite3,stat,statistics,struct,uuid
from urllib.parse import quote

def sha(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def need(value,message):
    if not value:raise ValueError(message)
def frame(values):
    out=bytearray(b'OWSR\x01'+bytes([len(values)]))
    for value in values:
        if value is None:out.append(0)
        elif type(value) is int:out.append(1);out.extend(struct.pack('<q',value))
        elif type(value) is float:need(math.isfinite(value),'Nonfinite source value');out.append(2);out.extend(struct.pack('<d',value))
        elif type(value) in (str,bytes):
            out.append(3 if type(value) is str else 4);data=value.encode('utf-8') if type(value) is str else value;out.extend(struct.pack('<Q',len(data)));out.extend(data)
        else:raise ValueError('Unsupported original SQLite cell')
    return bytes(out)
def key_name(data):
    need(type(data) is bytes and data.startswith(b'OWSR\x01\x01\x03') and len(data)>=15,'Invalid source primary frame')
    n=struct.unpack('<Q',data[7:15])[0];need(15+n==len(data),'Truncated/trailing source primary frame');value=data[15:].decode('utf-8');need(frame([value])==data,'Noncanonical source primary frame');return value

def review(root):
    root=pathlib.Path(root).absolute();need(root.is_dir() and not root.is_symlink(),'Fixture root must be a real directory')
    need((root/'owned-fixture').read_bytes()==b'OSwind authored identity bootstrap scale fixture v1','Missing authored identity marker')
    report_path=root/'report.json';r=json.loads(report_path.read_text());run=json.loads((root/'run.json').read_text())
    need(r['format']=='OSwind owned identity bootstrap scale component v1' and r['state']=='completed' and r['rows'] in [1000,100000,1000000],'Incomplete or unrecognized authored fixture')
    count=r['rows'];need(type(count) is int,'Invalid source count')
    need(run['state']=='completed' and run['returncode']==0 and run['rows']==count,'Actual successful test driver receipt required')
    log=pathlib.Path(run['logPath']);need(sha(log)==run['logSHA256'],'Test log hash changed');text=log.read_text()
    case="Test Case '-[OSwindCoreTests.SyncIdentityScaleTests testOwnedIdentityBootstrapAndIncrementalLifetimeScale]' passed"
    need(text.count(case)==1 and f'IDENTITY_SCALE rows={count} ' in text,'Actual scale entry did not pass exactly once')
    summaries=re.findall(r'Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures? \((\d+) unexpected\)',text)
    need(summaries and int(summaries[-1][2])==0 and int(summaries[-1][3])==0,'Test run has failures')
    inputs=pathlib.Path(run['sourceInputsPath']);need(sha(inputs)==run['sourceInputsSHA256'],'Source manifest changed');repo=pathlib.Path.cwd()
    frozen=json.loads(inputs.read_text());need(all(sha(repo/p)==h for p,h in frozen.items()),'A declared test/source input changed')
    db=root/'library/memory.sqlite';need(stat.S_ISREG(db.lstat().st_mode) and not db.is_symlink(),'Source database must be regular')
    for suffix in ['-wal','-journal']:
        side=db.with_name(db.name+suffix);need(not side.exists() or side.stat().st_size==0,'Archive has a live journal')
    before=sha(db);conn=sqlite3.connect('file:'+quote(str(db.resolve()))+'?mode=ro&immutable=1',uri=True)
    try:
        need(conn.execute('PRAGMA quick_check').fetchall()==[('ok',)],'Archive integrity check failed')
        need(conn.execute('PRAGMA user_version').fetchone()==(25,),'Unexpected library schema')
        h=hashlib.sha256();seen=bytearray(count);rows=0
        sql='SELECT id,timestamp,kind,app,title,url,text,favorite,payload,embedding,embedding_model FROM memories ORDER BY id COLLATE BINARY'
        for row in conn.execute(sql):
            ident,timestamp,kind,app,title,url,body,favorite,payload,embedding,model=row
            need(type(ident) is str and ident.startswith('identity-'),'Unexpected original source ID')
            ordinal=int(ident[9:]);need(1<=ordinal<=count and ident==f'identity-{ordinal}' and not seen[ordinal-1],'Original source membership differs');seen[ordinal-1]=1
            need(timestamp==1700000000 and kind=='note' and app=='Owned identity scale' and title=='Identity source' and url is None and body==f'Owned identity source {ordinal}' and favorite==0 and embedding is None and model is None,'Authored source fields differ')
            need(type(payload) is bytes,'Source payload storage differs');value=json.loads(payload);need(value['id']==ident and value['text']==body,'Authored payload identity/text differ')
            data=frame(row);h.update(struct.pack('<Q',len(data)));h.update(data);rows+=1
        digest=h.hexdigest();need(rows==count and all(seen) and r['originalTypedSHA256Before']==r['originalTypedSHA256After']==digest,'Original typed source digest differs')
        scope=conn.execute('SELECT origin,generation,enabled,used_bytes FROM personal_sync_capture WHERE singleton=1').fetchone();need(scope and scope[2:]==(1,0),'Capture accounting differs')
        need(str(uuid.UUID(scope[0]))==scope[0] and str(uuid.UUID(scope[1]))==scope[1],'Capture identity differs')
        need(conn.execute('SELECT origin,generation,through_seq,processing FROM personal_sync_identity_state WHERE singleton=1').fetchone()==(scope[0],scope[1],4,0),'Identity cursor/accounting differs')
        seen=bytearray(count);live=0;deleted=[]
        for obj,table,origin,lifetime,local_key,primary,is_deleted in conn.execute('SELECT object_digest,table_name,origin,lifetime,local_key,key_frame,deleted FROM personal_sync_identities'):
            need(table=='memories' and origin==scope[0] and str(uuid.UUID(lifetime))==lifetime,'Unexpected object origin/table/lifetime')
            expected=hashlib.sha256(b'OSwind.sync.object.v1\0source\0'+frame([table,origin,lifetime])).hexdigest();need(obj==expected,'Global object digest differs')
            need(type(local_key) is bytes and len(local_key)==32 and is_deleted in [0,1],'Invalid local object key/state')
            if is_deleted:
                need(primary is None and local_key==hashlib.sha256(frame(['owned-lifecycle-probe'])).digest(),'Deleted raw key or unexpected tombstone');deleted.append(obj);continue
            ident=key_name(primary);need(local_key==hashlib.sha256(primary).digest(),'Local source-key hash differs')
            need(ident.startswith('identity-'),'Unexpected live identity key');ordinal=int(ident[9:]);need(1<=ordinal<=count and ident==f'identity-{ordinal}' and not seen[ordinal-1],'Live identity membership differs');seen[ordinal-1]=1
            need(conn.execute('SELECT object_digest FROM personal_sync_identity_current WHERE table_name=? AND local_key=?',(table,local_key)).fetchone()==(obj,),'Current object mapping differs');live+=1
        need(live==count and all(seen) and len(deleted)==len(set(deleted))==2,'Live identities/tombstones differ')
        expected_metadata=dict(identities=count+2,live=count,tombstones=2,currentKeys=count+1,pending=0,deletedRawKeys=0,completedWithoutRawCursor=1)
        need(r['metadata']==expected_metadata,'Reported metadata differs')
        need(conn.execute('SELECT COUNT(*) FROM personal_sync_identity_current').fetchone()==(count+1,),'Current key count differs')
        need(conn.execute('SELECT COUNT(*) FROM personal_sync_changes').fetchone()==(0,),'Pending source intents remain')
        need(conn.execute('SELECT table_name,next_key,cursor_key,complete FROM personal_sync_identity_bootstrap').fetchall()==[('memories',None,None,1)],'Completed bootstrap retains a raw cursor')
        increments=r['incremental'];need(len(increments)==4,'Missing lifecycle observations')
        first,fresh=increments[0]['after'],increments[2]['after'];need(first!=fresh and set(deleted)=={first,fresh},'Recreated lifetime did not change')
        need([(v['before'],v['after']) for v in increments]==[(None,first),(first,None),(None,fresh),(fresh,None)],'Incremental lifecycle order differs')
        need(all(type(v['milliseconds']) in (int,float) and math.isfinite(v['milliseconds']) and v['milliseconds']>=0 for v in increments),'Invalid lifecycle timing')
        batches=r['bootstrapBatches'];need(r['batchLimit']==128 and r['keyByteLimit']==1048576 and len(batches)==math.ceil(count/128),'Bootstrap batch bounds differ')
        need(sum(v['objects'] for v in batches)==count and all(v['objects']==128 and not v['complete'] for v in batches[:-1]) and batches[-1]['objects']==(count%128 or 128) and batches[-1]['complete'] is True,'Bootstrap batch membership/counts differ')
        raw=[v['milliseconds'] for v in batches];need(all(type(v) in (int,float) and math.isfinite(v) and v>=0 for v in raw),'Invalid bootstrap timing')
        need(r['batchMedianMS']==statistics.median(raw) and r['batchP95MS']==sorted(raw)[math.ceil(.95*len(raw))-1],'Bootstrap quantiles differ')
        need(type(r['bootstrapSeconds']) in (int,float) and math.isfinite(r['bootstrapSeconds']) and r['bootstrapSeconds']>0 and r['bootstrapSeconds']+1e-6>=sum(raw)/1000,'Invalid aggregate bootstrap timing')
    finally:conn.close()
    need(sha(db)==before,'Read-only review changed the archive')
    result=dict(format='OSwind independent identity-scale review',state='completed',rows=count,reportSHA256=sha(report_path),runReceiptSHA256=sha(root/'run.json'),databaseSHA256=before,originalTypedSourceSHA256=digest,allOriginalTypedFieldsAndPayloadsVerified=True,allGlobalLifetimeAndLocalPrimaryDigestsVerified=True,allCurrentMappingsVerified=True,deletionRecreationAndRawKeyPurgingVerified=True,actualSuccessfulTestEntryVerified=True,allBatchCountsAndQuantilesRecomputed=True,declaredInputsUnchanged=len(frozen),reviewerSHA256=sha(pathlib.Path(__file__)),scope='Read-only independent authored-source and catalog inspection after actual test exit. Reported timings/quantiles verified arithmetically; no independent hardware clock/RSS instrumentation, typed content transfer, GPU/energy, provider/two-Mac or competitor qualification.')
    out=root/'independent-review.json';need(not out.exists(),'Review output must be fresh');out.write_text(json.dumps(result,indent=2)+'\n');return result

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('root',type=pathlib.Path);args=parser.parse_args();print(json.dumps(review(args.root),indent=2))
