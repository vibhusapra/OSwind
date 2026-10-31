#!/usr/bin/env python3
"""Read-only independent review of marked authored typed-version scale archives."""
import argparse,hashlib,importlib.util,json,math,os,pathlib,sqlite3,stat,statistics,struct,uuid

_helper=pathlib.Path(__file__).with_name('review-sync-identity-scale.py')
_spec=importlib.util.spec_from_file_location('owned_identity_frame_reader',_helper)
_frame_module=importlib.util.module_from_spec(_spec);_spec.loader.exec_module(_frame_module)
frame=_frame_module.frame

def need(value,message):
    if not value:raise ValueError(message)
def sha(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def canonical_uuid(value):
    return type(value) is str and str(uuid.UUID(value))==value
def digest(value):return hashlib.sha256(value).hexdigest()
def review(root,*,outgoing=False):
    root=pathlib.Path(root).absolute();need(root.resolve()==root and root.is_dir() and not root.is_symlink(),'Authored output must be a nonsymlink absolute directory')
    metadata=root.stat();need(metadata.st_uid==os.getuid() and stat.S_IMODE(metadata.st_mode)==0o700,'Private authored output ownership differs')
    marker=root/'owned-fixture';expected_marker=b'OSwind authored outgoing preparation v1' if outgoing else b'OSwind authored version preparation v1';need(marker.is_file() and not marker.is_symlink() and marker.read_bytes()==expected_marker,'Missing authored version fixture marker')
    report_path=root/'report.json';need(report_path.is_file() and not report_path.is_symlink() and report_path.stat().st_size<2*1024*1024,'Invalid version report')
    reports=json.loads(report_path.read_text());need(type(reports) is list and [r.get('count') for r in reports]==[1000,10000],'Unexpected authored version fixture sizes')
    results=[]
    for r in reports:
        count=r['count'];directory=root/('n%d'%count);need(directory.resolve()==directory and directory.is_dir(),'Authored size directory differs')
        own_report=directory/'report.json';need(json.loads(own_report.read_text())==r,'Per-size report differs')
        library=directory/'library';db=library/'memory.sqlite';need(library.resolve()==library and db.is_file() and not db.is_symlink() and db.stat().st_size<512*1024*1024,'Unsafe authored database')
        wal=library/'memory.sqlite-wal';need(not wal.exists() or (wal.is_file() and not wal.is_symlink() and wal.stat().st_size==0),'Review only a closed journal-free authored snapshot')
        files={p.name:sha(p) for p in library.glob('memory.sqlite*') if p.is_file()};connection=sqlite3.connect(db.as_uri()+'?mode=ro&immutable=1',uri=True)
        try:
            need(connection.execute('PRAGMA user_version').fetchone()[0]==25,'Canonical schema version differs')
            need(connection.execute('SELECT COUNT(*) FROM memories').fetchone()[0]==count,'Source membership differs')
            columns='id,timestamp,kind,app,title,url,text,favorite,payload,embedding,embedding_model'
            originals=connection.execute('SELECT '+columns+' FROM memories ORDER BY id COLLATE BINARY').fetchall()
            scope=connection.execute('SELECT origin,generation,enabled,suppressed,used_bytes FROM personal_sync_capture').fetchall();need(len(scope)==1 and scope[0][2:]==(1,0,0),'Capture state differs');origin,generation=scope[0][:2];need(canonical_uuid(origin) and canonical_uuid(generation),'Invalid capture namespace')
            replica='00000000-0000-0000-0000-000000000711';group='00000000-0000-0000-0000-000000000712';epoch='00000000-0000-0000-0000-000000000713'
            need(connection.execute('SELECT replica,group_id,epoch,sequence FROM personal_sync_local').fetchall()==[(replica,group,epoch,count)],'Journal scope/counter differs')
            local=connection.execute('SELECT origin,generation,through_seq,processing FROM personal_sync_identity_state').fetchall();need(local==[(origin,generation,0,0)],'Identity state differs')
            bootstrap=connection.execute('SELECT table_name,next_key,cursor_key,complete FROM personal_sync_identity_bootstrap ORDER BY table_name').fetchall()
            tables=['memories','chat_sessions','chat_turns','chat_sources','recap_sources','routines','routine_runs','memory_entities','entity_aliases','entity_mentions','entity_ignored','entity_project_ignored','text_observation_pins'] if outgoing else ['memories']
            need(bootstrap==[(table,None,None,1) for table in sorted(tables)],'Bootstrap did not finish without a raw cursor')
            if outgoing:
                for table in tables:
                    if table!='memories':need(connection.execute('SELECT COUNT(*) FROM '+table).fetchone()[0]==0,'Unexpected canonical graph rows in note-only fixture')
                need(connection.execute('SELECT COUNT(*) FROM personal_sync_work').fetchone()[0]==0,'Outgoing work remains')
                need(connection.execute('SELECT origin,generation,processing,used_bytes,budget FROM personal_sync_work_state').fetchall()==[(origin,generation,0,0,67108864)],'Outgoing work context/accounting differs')
            identities=connection.execute('SELECT object_digest,table_name,origin,lifetime,local_key,key_frame,deleted FROM personal_sync_identities').fetchall();need(len(identities)==count,'Identity membership differs');by_key={x[4]:x for x in identities};need(len(by_key)==count,'Duplicate local identity key')
            current=dict(connection.execute("SELECT local_key,object_digest FROM personal_sync_identity_current WHERE table_name='memories'"));need(len(current)==count,'Current mappings differ')
            versions={x[0]:x[1:] for x in connection.execute('SELECT object_digest,content_sha,table_name,local_key,bytes,body FROM personal_sync_versions')};need(len(versions)==count,'Version membership differs')
            projections={x[0]:x[1:] for x in connection.execute('SELECT object_digest,content_sha,row_digest,evidence,entity_revision FROM personal_sync_version_projection')};need(len(projections)==count,'Projection membership differs')
            registers={x[0]:json.loads(x[1]) for x in connection.execute("SELECT digest,state FROM personal_sync_registers WHERE kind='source'")};need(len(registers)==count,'Register membership differs')
            outbox={x[0]:json.loads(x[1]) for x in connection.execute('SELECT sequence,revision FROM personal_sync_outbox')};need(len(outbox)==count,'Outbox membership differs')
            for name in ['personal_sync_changes','personal_sync_pending','personal_sync_version_recipes','personal_sync_version_sessions','personal_sync_version_runs','personal_sync_version_revoked']:
                need(connection.execute('SELECT COUNT(*) FROM '+name).fetchone()[0]==0,'Unexpected authored pending/graph state')
            original_hash=hashlib.sha256();logical=0
            for ordinal,row in enumerate(originals,1):
                identifier='version-%08d'%ordinal;text='Owned version source %d'%ordinal
                need(row[:8]==(identifier,1700000000.0,'note','Owned version scale','Version source',None,text,0) and row[9:]==(None,None),'Authored source columns differ')
                payload=json.loads(row[8]);expected=dict(id=identifier,timestamp=721692800,kind='note',app='Owned version scale',bundleID='',title='Version source',text=text,regions=[],favorite=False,tags=[]);need(payload==expected,'Authored original Memory payload differs')
                raw_frame=frame(row);original_hash.update(struct.pack('<Q',len(raw_frame)));original_hash.update(raw_frame)
                primary=frame([identifier]);key=hashlib.sha256(primary).digest();identity=by_key.get(key);need(identity is not None,'Original source identity is missing')
                object_digest,table,object_origin,lifetime,stored_key,stored_primary,deleted=identity
                need(table=='memories' and object_origin==origin and canonical_uuid(lifetime) and stored_key==key and stored_primary==primary and deleted==0,'Original identity binding differs')
                expected_digest=digest(b'OSwind.sync.object.v1\0source\0'+frame([table,origin,lifetime]));need(object_digest==expected_digest and current.get(key)==object_digest,'Global/current object digest differs')
                version=versions.get(object_digest);need(version is not None,'Original typed version missing');content_sha,table_name,local_key,size,body=version
                need(table_name=='memories' and local_key==key and type(size) is int and size==len(body) and content_sha==digest(body),'Typed content integrity differs');logical+=size+128
                packet=json.loads(body);need(set(packet)=={'format','version','identity','body'} and packet['format']=='OSwind.sync.record' and packet['version']==1 and packet['identity']==dict(table='memories',origin=origin,lifetime=lifetime),'Typed packet identity differs')
                expected_source={k:v for k,v in expected.items() if k!='id'};expected_source['media']=[];need(packet['body']==dict(source={'_0':expected_source}),'Portable source differs from its original payload')
                need(json.dumps(packet,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()==body,'Noncanonical packet bytes')
                content=digest(('Version source\nOwned version scale\n\n'+text).encode());bits=struct.unpack('<Q',struct.pack('<d',721692800.0))[0];entity=content+':'+str(bits)+':note';evidence=entity+':'
                need(projections.get(object_digest)==(content_sha,digest(frame(row[:9])),evidence,entity),'Exact local projection/evidence domains differ')
                key_object=dict(kind='source',digest=object_digest);reference=dict(sha256=content_sha,bytes=size);head=dict(key=key_object,dot=dict(replica=replica,counter=ordinal),context={} if ordinal==1 else {replica:ordinal-1},mutation='put',content=reference)
                need(outbox.get(ordinal)==head,'Typed journal operation differs');need(registers.get(object_digest)==dict(key=key_object,clock={replica:ordinal},deletions={},heads=[head]),'Durable typed register differs')
            need(original_hash.hexdigest()==r['sourceOriginalSHA256'],'Original typed source hash differs')
            state=connection.execute('SELECT origin,generation,group_id,epoch,used_bytes,budget FROM personal_sync_version_state').fetchall();need(state==[(origin,generation,group,epoch,logical,1073741824)],'Version scope/accounting differs')
            need(r['metadata']==dict(versions=count,projections=count,outbox=count,usedBytes=logical),'Reported accounting differs')
        finally:connection.close()
        need({p.name:sha(p) for p in library.glob('memory.sqlite*') if p.is_file()}==files,'Readonly review changed authored SQLite files')
        batches=r['batches'];need(len(batches)==math.ceil(count/128) and sum(x['objects'] for x in batches)==count and all(type(x['objects']) is int and 0<x['objects']<=128 and math.isfinite(x['seconds']) and x['seconds']>=0 for x in batches),'Invalid bounded preparation batches')
        times=[x['seconds'] for x in batches];need(math.isfinite(r['prepareSeconds']) and r['prepareSeconds']>=sum(times),'Invalid preparation timer')
        if outgoing:
            steps=r['steps'];need(all(type(s) is dict and s.get('kind') in ['prepared','bootstrap','idle'] and type(s.get('objects')) is int and 0<=s['objects']<=128 and math.isfinite(s.get('seconds',-1)) and s['seconds']>=0 for s in steps),'Invalid outgoing step')
            need(steps[-1]['kind']=='idle' and sum(s['kind']=='idle' for s in steps)==1 and sum(s['objects'] for s in steps if s['kind']=='bootstrap')==count,'Outgoing step membership differs')
            need(set(s.get('table') for s in steps if s['kind']=='bootstrap')==set(tables),'Outgoing bootstrap table coverage differs')
            need([dict(objects=s['objects'],seconds=s['seconds']) for s in steps if s['kind']=='prepared']==batches and r['prepareSeconds']>=sum(s['seconds'] for s in steps),'Outgoing step timing differs')
        results.append(dict(count=count,sourceOriginalSHA256=r['sourceOriginalSHA256'],sourceRowsAndTypedPacketsVerified=count,journalAndProjectionBindingsVerified=True,sqliteFilesUnchanged=files,reportSHA256=sha(own_report),prepareSeconds=r['prepareSeconds'],batchMedianSeconds=statistics.median(times),batchP95Seconds=sorted(times)[math.ceil(.95*len(times))-1],logicalCacheBytes=logical))
    return dict(state='reviewed',outgoing=outgoing,readerSHA256=sha(pathlib.Path(__file__)),independentFrameReaderSHA256=sha(_helper),inputReportSHA256=sha(report_path),results=results,scope='All authored source cells/payloads, global lifetimes, local/wire version bindings, typed bytes, journal/registers, accounting and batch summaries independently checked. Outgoing mode additionally verifies all 13 finished bootstrap cursors, drained work/context/accounting and step membership/timers. Immutable readonly closed snapshots. Warm note-only preparation, not model/media/transport/capture/energy or competitor ranking.')

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('root',type=pathlib.Path);parser.add_argument('--outgoing',action='store_true');args=parser.parse_args()
    try:result=review(args.root,outgoing=args.outgoing)
    except (ValueError,OSError,sqlite3.Error,KeyError,TypeError,IndexError) as error:parser.exit(1,'Review refused: '+str(error)+'\n')
    print(json.dumps(result,indent=2,sort_keys=True))
if __name__=='__main__':main()
