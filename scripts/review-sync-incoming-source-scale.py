#!/usr/bin/env python3
"""Read-only independent review of closed, authored incoming-source scale output."""
import argparse,contextlib,hashlib,importlib.util,json,math,pathlib,sqlite3,stat,struct,uuid
helper=pathlib.Path(__file__).with_name('review-sync-identity-scale.py')
spec=importlib.util.spec_from_file_location('owned_frame_reader',helper);frames=importlib.util.module_from_spec(spec);spec.loader.exec_module(frames)
SCHEMAS={
 'memories':('id,timestamp,kind,app,title,url,text,favorite,payload','id','source'),
 'chat_sessions':('id,title,created,updated','id','conversation'),
 'chat_turns':('id,session_id,timestamp,payload','id','turn'),
 'chat_sources':('turn_id,memory_id,ordinal,score,match,passage_start,passage_length,owner_id,historical_handle','turn_id,ordinal','conversationCitation'),
 'recap_sources':('recap_id,source_id,ordinal,revision,score,match,passage_start,passage_length,owner_id,historical_handle','recap_id,ordinal','recapCitation'),
 'text_observation_pins':('memory_id','memory_id','evidencePin')}
TABLES=list(SCHEMAS)+['routines','routine_runs','memory_entities','entity_aliases','entity_mentions','entity_ignored','entity_project_ignored','historical_evidence']
def need(value,message):
 if not value:raise ValueError(message)
def sha(data):return hashlib.sha256(data).hexdigest()
def encode(value):return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()
def key(data):
 need(data[:5]==b'OWSR\1','Key frame header differs');offset=6;result=[]
 for _ in range(data[5]):
  kind=data[offset];offset+=1
  if kind==1:result.append(struct.unpack('<q',data[offset:offset+8])[0]);offset+=8
  else:
   need(kind==3,'Key storage class differs');size=struct.unpack('<Q',data[offset:offset+8])[0];offset+=8;result.append(data[offset:offset+size].decode());offset+=size
 need(offset==len(data) and frames.frame(result)==data,'Key frame differs');return result

def evidence(memory):
 text='\n'.join([memory['title'],memory['app'],memory.get('url',''),memory['text']]);bits=struct.unpack('<Q',struct.pack('<d',memory['timestamp']))[0]
 result=sha(text.encode())+':'+str(bits)+':'+memory['kind']+':'
 if 'recap' in memory:result+=':'+sha(encode(memory['recap']))
 return result

def native(body,ident,parents,historical=False):
 value={k:v for k,v in body.items() if k not in ['media','recap','audioSession']};value['id']=ident
 need(body['media']==[] and 'audioSession' not in body and 'transcript' not in body and 'visualRecording' not in body,'Unexpected scale media/model source')
 if 'recap' in body:
  sources=[]
  for link,(handle,owner,memory) in zip(body['recap']['sources'],parents):
   source={k:v for k,v in link.items() if k!='source'};source.update(id='original-'+handle if historical else owner,revision=evidence(memory),historicalHandle=handle);sources.append(source)
  need(len(sources)==len(body['recap']['sources']),'Native parent width differs');value['recap']=dict(provider=body['recap']['provider'],sources=sources)
 return value

def review(root):
 root=pathlib.Path(root).absolute();need(root.resolve()==root and root.is_dir() and not root.is_symlink(),'Invalid owned root');need(stat.S_IMODE(root.stat().st_mode)==0o700 and (root/'owned-fixture').read_bytes()==b'OSwind authored incoming source scale v1','Owned marker differs')
 reports=json.loads((root/'report.json').read_text());need([r['count'] for r in reports]==[1000,10000],'Scale sizes differ');results=[];pins={}
 for r in reports:
  size=r['count'];base=root/('n%d'%size);need(json.loads((base/'report.json').read_text())==r and r['librarySchema'] in (28,29) and r['incomingObjects']==size and r['updatedObjects']==10,'Scale report differs')
  need(r['batchSize']==128 and sum(b['objects'] for b in r['batches'])==size and all(0<b['objects']<=128 and math.isfinite(b['seconds']) and b['seconds']>=0 for b in r['batches']),'Batch coverage/timings differ')
  for name in ['loadSeconds','outgoingPreparationSeconds','incomingSeconds','citedUpdateSeconds']:need(type(r[name]) in [int,float] and math.isfinite(r[name]) and r[name]>=0,'Invalid timer')
  p=base/'receiver/memory.sqlite';need(p.resolve()==p and p.is_file() and not p.is_symlink(),'Invalid receiver file')
  for suffix in ['-wal','-journal']:need(not p.with_name(p.name+suffix).exists() or p.with_name(p.name+suffix).stat().st_size==0,'Receiver journal remains')
  producer=base/'producer/memory.sqlite';need(producer.resolve()==producer and producer.is_file() and not producer.is_symlink(),'Invalid producer file')
  for suffix in ['-wal','-journal']:need(not producer.with_name(producer.name+suffix).exists() or producer.with_name(producer.name+suffix).stat().st_size==0,'Producer journal remains')
  producer_before=sha(producer.read_bytes());expected_sources={}
  with contextlib.closing(sqlite3.connect(producer.as_uri()+'?mode=ro&immutable=1',uri=True)) as source_db:
   need(source_db.execute('PRAGMA user_version').fetchone()==(r['librarySchema'],) and source_db.execute('PRAGMA quick_check').fetchall()==[('ok',)] and not source_db.execute('PRAGMA foreign_key_check').fetchall(),'Producer integrity differs')
   for obj,raw,content,packet in source_db.execute("SELECT i.object_digest,i.key_frame,p.content_sha,v.body FROM personal_sync_identities i JOIN personal_sync_version_projection p ON p.object_digest=i.object_digest JOIN personal_sync_versions v ON v.object_digest=p.object_digest AND v.content_sha=p.content_sha WHERE i.table_name='memories' AND i.deleted=0"):
    primary=key(raw);need(len(primary)==1 and primary[0].startswith('incoming-'),'Producer source key differs');index=int(primary[0][9:]);need(primary[0]=='incoming-%08d'%index and 1<=index<=size and content==sha(packet),'Producer exact source differs');expected_sources[obj]=(index,content,packet)
   need(len(expected_sources)==size and source_db.execute('SELECT count(*) FROM personal_sync_changes').fetchone()==(0,),'Producer source membership/pending changes differ')
  need(sha(producer.read_bytes())==producer_before,'Readonly review changed producer');pins[str(producer.relative_to(root))]=producer_before
  before=sha(p.read_bytes())
  with contextlib.closing(sqlite3.connect(p.as_uri()+'?mode=ro&immutable=1',uri=True)) as db:
   need(db.execute('PRAGMA user_version').fetchone()==(r['librarySchema'],) and db.execute('PRAGMA quick_check').fetchall()==[('ok',)] and not db.execute('PRAGMA foreign_key_check').fetchall(),'Receiver integrity differs')
   for prefix,marker in [('historical_scope_writer_','oswind_historical_scope_writer_v1'),('incoming_source_writer_','oswind_incoming_source_writer_v1')]:
    actual=dict(db.execute("SELECT name,sql FROM sqlite_master WHERE type='trigger' AND name GLOB ?",(prefix+'*',)));expected={f'{prefix}{t}_{op}':f'CREATE TRIGGER {prefix}{t}_{op} BEFORE {op.upper()} ON {t} BEGIN SELECT {marker}(); END' for t in TABLES for op in ['insert','update','delete']};need(actual==expected,'Writer protection differs')
   if r['librarySchema']>=29:frames.verify_run_original_schema(db,require_empty=True)
   for table in TABLES:
    if table not in SCHEMAS and table!='historical_evidence':need(db.execute('SELECT count(*) FROM '+table).fetchone()==(0,),'Unexpected unrelated native graph')
   need(db.execute('SELECT count(*) FROM personal_sync_changes').fetchone()==(0,),'Unexpected outgoing echo')
   need(db.execute('SELECT count(*) FROM personal_sync_outbox').fetchone()==(r['receiverOutbox'],),'Outbox membership differs')
   identities={}
   for obj,table,origin,lifetime,local,raw,deleted in db.execute('SELECT object_digest,table_name,origin,lifetime,local_key,key_frame,deleted FROM personal_sync_identities'):
    need(table in SCHEMAS and deleted==0 and str(uuid.UUID(origin))==origin and str(uuid.UUID(lifetime))==lifetime,'Identity fields differ');primary=key(raw)
    need(obj==sha(b'OSwind.sync.object.v1\0'+SCHEMAS[table][2].encode()+b'\0'+frames.frame([table,origin,lifetime])) and local==hashlib.sha256(raw).digest(),'Identity digest differs')
    need(db.execute('SELECT object_digest FROM personal_sync_identity_current WHERE table_name=? AND local_key=?',(table,local)).fetchone()==(obj,),'Current identity binding differs');identities[obj]=(table,primary,local,dict(table=table,origin=origin,lifetime=lifetime))
   packets={}
   for obj,content,table,local,charged,body in db.execute('SELECT object_digest,content_sha,table_name,local_key,bytes,body FROM personal_sync_versions'):
    need(obj in identities and table==identities[obj][0] and local==identities[obj][2] and charged==len(body) and content==sha(body),'Exact packet hash/charge/binding differs');packet=json.loads(body);need(packet['format']=='OSwind.sync.record' and packet['version']==1 and packet['identity']==identities[obj][3],'Packet identity differs');packets[obj,content]=(packet,body)
   need(len(packets)==r['receiverVersions'],'Version count differs');current={}
   for obj,content,rowhash in db.execute('SELECT object_digest,content_sha,row_digest FROM personal_sync_version_projection'):
    table,primary,_,_=identities[obj];columns,keys,_=SCHEMAS[table];row=db.execute('SELECT '+columns+' FROM '+table+' WHERE '+' AND '.join(k+' IS ?' for k in keys.split(',')),primary).fetchone();need(row is not None and sha(frames.frame(row))==rowhash,'Actual current native frame differs');need((obj,content) in packets,'Projected packet missing');current[obj]=(content,row)
   need(len(current)==len(identities),'Missing current projection')
   archive={row[0]:row[1:] for row in db.execute('SELECT handle,source_id,object_digest,content_sha,body,paths,parents,projection_sha FROM historical_evidence')};need(len(archive)==30,'Original membership differs');decoded={};active=set()
   def original(handle):
    if handle in decoded:return decoded[handle]
    need(handle not in active and len(active)<32,'Archive cycle or depth differs');active.add(handle)
    owner,obj,content,body,paths,parent_data,projection=archive[handle];packet=json.loads(body);need((obj,content) in packets and packets[obj,content][1]==body and content==sha(body) and paths==b'{}','Original exact bytes differ')
    source=packet['body']['source']['_0'];parents=json.loads(parent_data);need(len(parents)==len(source.get('recap',{}).get('sources',[])),'Original parent width differs')
    need({x[0] for x in db.execute('SELECT parent FROM historical_evidence_dependencies WHERE child=?',(handle,))}==set(parents),'Original edge membership differs');values=[]
    for link,parent in zip(source.get('recap',{}).get('sources',[]),parents):
     memory=original(parent);parent_row=archive[parent];need(link['source']==dict(identity=json.loads(parent_row[3])['identity'],content=dict(sha256=parent_row[2],bytes=len(parent_row[3]))),'Exact original parent differs');values.append((parent,parent_row[0],memory))
    value=native(source,'original-'+handle,values,True);binding=[handle,owner,obj,content,str(len(body))]
    need(projection==sha(b'OSwind.historical-evidence.v1\0'+encode(binding)+b'\0'+encode(value)),'Original native projection differs');active.remove(handle);decoded[handle]=value;return value
   for handle in archive:original(handle)
   charge=sum(256+len(row[3])+len(row[4])+len(row[5])+128*len(json.loads(row[5])) for row in archive.values());need(db.execute('SELECT used_bytes FROM historical_evidence_state').fetchone()==(charge,),'Original accounting differs')
   exact_versions={(row[1],row[2]):handle for handle,row in archive.items()};notes=0;summaries=0;seen_notes=set()
   for obj,(content,row) in current.items():
    if identities[obj][0]!='memories':continue
    packet=packets[obj,content][0];source=packet['body']['source']['_0'];parents=[]
    for link in source.get('recap',{}).get('sources',[]):
     ref=link['source'];identity=ref['identity'];digest=sha(b'OSwind.sync.object.v1\0source\0'+frames.frame([identity['table'],identity['origin'],identity['lifetime']]));handle=exact_versions[digest,ref['content']['sha256']];parents.append((handle,archive[handle][0],decoded[handle]))
    expected=native(source,row[0],parents);need(json.loads(row[8])==expected,'Native source content differs from exact wire body/provenance')
    if source['kind']=='note':
     need(obj in expected_sources and expected_sources[obj][1:]==(content,packets[obj,content][1]),'Incoming current version differs from actual outgoing producer');text=source['text'];prefix='Owned newer incoming source ' if text.startswith('Owned newer') else 'Owned incoming source ';number=int(text[len(prefix):].split(' ',1)[0]);need(1<=number<=size and text==prefix+str(number)+' '+'x'*1024 and (prefix.startswith('Owned newer')==(number<=10)),'Authored current note fields differ');need(number==expected_sources[obj][0] and number not in seen_notes,'Original producer ordinal membership differs');seen_notes.add(number);notes+=1
    else:need(source['kind']=='summary','Unexpected source kind');summaries+=1

   pin_count=0
   for obj,(content,row) in current.items():
    table=identities[obj][0]
    if table not in ['chat_sources','recap_sources','text_observation_pins']:continue
    body=packets[obj,content][0]['body'][SCHEMAS[table][2]]['_0'];ref=body['source'] if table=='text_observation_pins' else body['link']['source'];identity=ref['identity'];source_digest=sha(b'OSwind.sync.object.v1\0source\0'+frames.frame([identity['table'],identity['origin'],identity['lifetime']]))
    handle=exact_versions[source_digest,ref['content']['sha256']];owner=archive[handle][0]
    if table=='text_observation_pins':
     need(row==(owner,) and db.execute('SELECT handle FROM historical_evidence_pins WHERE memory_id=?',(owner,)).fetchone()==(handle,),'Historical pin version differs');pin_count+=1;continue
    link=body['link'];passage=link.get('passage');start=None if passage is None else passage['start'];length=None if passage is None else passage['length'];identity=body['owner'];owner_kind=SCHEMAS[identity['table']][2];owner_digest=sha(b'OSwind.sync.object.v1\0'+owner_kind.encode()+b'\0'+frames.frame([identity['table'],identity['origin'],identity['lifetime']]));local=identities[owner_digest][1][0]
    expected=(local,None,body['ordinal'])+((evidence(decoded[handle]),) if table=='recap_sources' else ())+ (link['score'],link['match'],start,length,owner,handle)
    need(row==expected,'Native citation owner/exact original fields differ')
   need(pin_count==30 and db.execute('SELECT count(*) FROM historical_evidence_pins').fetchone()==(30,),'Historical pin membership differs')
   need(notes==size and seen_notes==set(range(1,size+1)) and summaries==20 and len(r['chains'])==10,'Source/recap counts differ')
   for chain in r['chains']:
    index=chain['index'];need(chain['oldText']=='Owned incoming source %d '%index+'x'*1024,'Original source oracle differs')
    for owner,text in [(chain['source'],chain['oldText']),(chain['recapOne'],'Owned chain %d first'%index),(chain['recapTwo'],'Owned chain %d second'%index)]:need(len([h for h,v in archive.items() if v[0]==owner and decoded[h]['text']==text])==1,'Preserved exact chain differs')
    need(db.execute('SELECT count(*) FROM chat_turns WHERE session_id=?',(chain['conversation'],)).fetchone()==(2,),'Cited answer membership differs')
  need(sha(p.read_bytes())==before,'Readonly review changed receiver');pins[str(p.relative_to(root))]=before;results.append(dict(count=size,currentProjections=len(current),cachedVersions=len(packets),originals=len(archive),incomingSeconds=r['incomingSeconds'],citedUpdateSeconds=r['citedUpdateSeconds']))
 return dict(state='reviewed',readerSHA256=sha(pathlib.Path(__file__).read_bytes()),frameReaderSHA256=sha(helper.read_bytes()),results=results,unchangedProducerAndReceiverSQLiteFiles=pins,scope='One warm authored 1KiB note run per size,128-record incoming transactions and ten cited updates with two recap levels. Exact current frames/packets, archival native projections/DAG/accounting and old chain content independently verified. Excludes media, models, transport, policy inference, cold cache, physical power and competitor ranking.')
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('root',type=pathlib.Path);a=p.parse_args();print(json.dumps(review(a.root),indent=2))
