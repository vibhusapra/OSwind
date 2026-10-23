#!/usr/bin/env python3
"""Synthetic long-lived MCP/storage/cache soak with concurrent CLI writes.
No screen/audio devices, HTTP listener, real library or permissions are used.
Sleep/clock gaps prevent a continuous-pass result. Optional answers use local
Ollama only; the script never starts/replaces a model daemon or retries failures.
"""
import argparse,collections,datetime,hashlib,json,os,pathlib,queue,re,shutil,signal,subprocess,sys,threading,time,uuid

def atomic(path,value):
    temporary=path.with_suffix('.pending');temporary.write_text(json.dumps(value,indent=2)+'\n');temporary.replace(path)

def digest(path):
    value=hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda:file.read(1024*1024),b''):value.update(chunk)
    return value.hexdigest()

class MCP:
    def __init__(self,prefix,log,timeout):
        self.process=subprocess.Popen(prefix+['mcp'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True,bufsize=1)
        self.responses=queue.Queue();self.sequence=0;self.timeout=timeout
        def read():
            try:
                for line in self.process.stdout:self.responses.put(json.loads(line))
            except BaseException as error:self.responses.put(error)
            finally:self.responses.put(None)
        self.reader=threading.Thread(target=read,daemon=True);self.reader.start()
        try:
            self.call('initialize',{'protocolVersion':'2025-11-25'})
            self.process.stdin.write(json.dumps({'jsonrpc':'2.0','method':'notifications/initialized'})+'\n');self.process.stdin.flush()
        except BaseException:self.close();raise
    def call(self,method,params):
        self.sequence+=1
        self.process.stdin.write(json.dumps({'jsonrpc':'2.0','id':self.sequence,'method':method,'params':params})+'\n');self.process.stdin.flush()
        try:response=self.responses.get(timeout=self.timeout)
        except queue.Empty:raise RuntimeError(f'MCP response deadline exceeded; process status={self.process.poll()}; no automatic restart')
        if response is None:raise RuntimeError(f'MCP exited unexpectedly: {self.process.poll()}')
        if isinstance(response,BaseException):raise response
        if response.get('id')!=self.sequence or 'error' in response:raise RuntimeError(f'Invalid MCP response: {response}')
        return response['result']
    def tool(self,name,**arguments):
        result=self.call('tools/call',{'name':name,'arguments':arguments})
        if result.get('isError'):raise RuntimeError(str(result))
        return json.loads(next(c['text'] for c in result['content'] if c['type']=='text'))
    def close(self):
        forced=False
        try:self.process.stdin.close()
        except OSError:pass
        try:self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            forced=True;self.process.terminate()
            try:self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:self.process.kill();self.process.wait(timeout=5)
        self.reader.join(timeout=1);self.process.stdout.close()
        return {'exit_code':self.process.returncode,'forced':forced}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary');p.add_argument('--root',required=True);p.add_argument('--seconds',type=float,default=86400);p.add_argument('--interval',type=float,default=20);p.add_argument('--max-notes',type=int,default=200);p.add_argument('--request-timeout',type=float,default=60);p.add_argument('--chat-model');p.add_argument('--chat-every',type=float,default=600);a=p.parse_args()
    if not (0<a.seconds<=604800 and 0<a.interval<=300 and 1<=a.max_notes<=10000 and 1<=a.request_timeout<=300 and 1<=a.chat_every<=604800):p.error('Use positive bounded durations, timeouts and corpus sizes')
    original=pathlib.Path(a.binary).resolve()
    if not original.is_file() or not os.access(original,os.X_OK):p.error('Choose an executable OSwind CLI')
    root=pathlib.Path(a.root).resolve();root.mkdir(mode=0o700,parents=True,exist_ok=False)
    try:
        runner=root/'runner';runner.mkdir(mode=0o700);binary=runner/'oswindctl';shutil.copy2(original,binary);binary.chmod(0o555)
        if digest(binary)!=digest(original):raise RuntimeError('Executable changed during pinning')
    except BaseException as error:
        atomic(root/'status.json',{'format':'OSwind synthetic component soak v1','state':'failed','stage':'pinning','cycles':0,'error':f'{type(error).__name__}: {error}'})
        return 1
    library=root/'library';prefix=[str(binary),'--data',str(library)]
    run_id=uuid.uuid4().hex;notes=collections.deque();client=None;log=None
    status={'format':'OSwind synthetic component soak v1','state':'starting','run_id':run_id,'binary_sha256':digest(binary),'harness_sha256':digest(pathlib.Path(__file__)),'runner':'runner/oswindctl','os':subprocess.check_output(['sw_vers','-productVersion'],text=True).strip(),'hardware':subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),'requested_wall_seconds':a.seconds,'interval_seconds':a.interval,'max_notes':a.max_notes,'chat_model':a.chat_model,'chat_every_seconds':a.chat_every,'controller_pid':os.getpid(),'started_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'cycles':0,'writes':0,'deletions':0,'answers':0,'writer_live_read_cycles':0,'oversize_wall_gaps':[],'expected_warning_policy':'Bounded-excerpt notices are retained; all other answer warnings fail the run','gap_interpretation':'An oversized wall gap may be sleep, clock change or slow work; none is treated as uninterrupted coverage','resource_scope':'Sampled RSS/lifetime CPU of persistent MCP only, excluding writer/model daemons; no power estimate','scope':'Persistent MCP client/server, concurrent CLI writer, keyword/full/preview retrieval, complete source reads, erasure and optional local Qwen answers. No capture/device/UI/power/competitor claim.'}
    atomic(root/'status.json',status)
    def cli(*args):
        result=subprocess.run(prefix+list(map(str,args)),capture_output=True,text=True,timeout=a.request_timeout*3)
        if result.returncode:raise RuntimeError(f'CLI {args[0]} failed: {result.stderr[-2000:]}')
        return result.stdout
    exit_code=1;previous_termination=signal.getsignal(signal.SIGTERM)
    def interrupted(_signal,_frame):raise KeyboardInterrupt('Termination requested')
    signal.signal(signal.SIGTERM,interrupted)
    try:
        json.loads(cli('benchmark-audio-search','--archive',library,'--prepare','--clips','2','--words','1000'))
        if a.chat_model:cli('reindex','--provider','apple')
        log=(root/'mcp-stderr.log').open('w');client=MCP(prefix,log,a.request_timeout)
        status['mcp_pid']=client.process.pid;status['state']='running';atomic(root/'status.json',status)
        expected_text=' '.join('token'+str(index) for index in range(1000))
        started=time.time();last_wall=started;next_chat=0;iteration=0
        with (root/'samples.jsonl').open('a',buffering=1) as samples:
            while True:
                cycle_started=time.monotonic();wall=time.time();gap=wall-last_wall
                if gap>a.interval*3 or gap<0:status['oversize_wall_gaps'].append({'after_cycle':iteration,'wall_seconds':gap})
                last_wall=wall
                if iteration and wall-started>=a.seconds:break
                marker=f'evt{iteration:09d}'
                text=f'OSwind synthetic soak {run_id} {marker}. Maya owns the synthetic preview release, due Friday.'
                writer=subprocess.Popen(prefix+['note',text],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                try:
                    live_before=writer.poll() is None
                    during=client.tool('memory_stats')['count']
                    live_after=writer.poll() is None
                    output,error=writer.communicate(timeout=a.request_timeout*3)
                    if writer.returncode:raise RuntimeError(f'Concurrent note writer failed: {error[-2000:]}')
                    if during not in (len(notes)+2,len(notes)+3):raise RuntimeError('Reader observed an impossible count during write')
                    if live_before and live_after:status['writer_live_read_cycles']+=1
                finally:
                    if writer.poll() is None:writer.terminate();writer.wait(timeout=10)
                identifier=output.strip();notes.append(identifier);status['writes']+=1
                hits=client.tool('search_memory',query=marker,mode='keyword',detail='preview')['hits']
                if [h['memory']['id'] for h in hits]!=[identifier]:raise RuntimeError('New write was not visible to persistent MCP search')
                while len(notes)>a.max_notes:
                    old=notes.popleft();source=client.tool('get_memory',id=old)
                    if not source['text'].startswith(f'OSwind synthetic soak {run_id} '):raise RuntimeError('Refusing to erase a source not created by this run')
                    cli('delete',old);status['deletions']+=1
                    erased=client.tool('search_memory',query=f'evt{status["deletions"]-1:09d}',mode='keyword')['hits']
                    if erased:raise RuntimeError('Erased source remains searchable')
                timed=client.tool('search_memory',query='token',mode='keyword',speaker='Maya',detail='preview')['hits']
                if {h['memory']['id'] for h in timed}!={'bench-audio-0','bench-audio-1'} or any(h['memory'].get('transcript') is not None or h['memory']['text']!=expected_text or h['memory']['searchPreview']['transcript']['segmentCount']!=1000 for h in timed):raise RuntimeError('Timed preview/source-count contract changed')
                full=client.tool('get_memory',id=timed[0]['memory']['id'])
                transcript=full['transcript'];segments=transcript['segments']
                intact=len(segments)==1000 and full['text']==expected_text and transcript['text']==expected_text and all(segment['text']=='token'+str(index) and abs(segment['start']-index*.35)<1e-9 and abs(segment['end']-(index*.35+.3))<1e-9 for index,segment in enumerate(segments))
                if not intact or 'searchPreview' in full:raise RuntimeError('Complete timed source text/timings changed')
                stats=client.tool('memory_stats')
                if stats['count']!=len(notes)+2:raise RuntimeError(f'Archive tally changed: {stats["count"]} versus{len(notes)+2}')
                answer_seconds=None;answer_record=None
                if a.chat_model and wall-started>=next_chat:
                    before=time.monotonic();answer=json.loads(cli('ask','--provider','ollama','--model',a.chat_model,'Who owns the synthetic preview release?'))
                    citations=[int(n) for n in re.findall(r'\[(\d+)\]',answer['text'])]
                    valid=bool(citations) and all(1<=n<=len(answer['sources']) and answer['sources'][n-1]['memory']['text'].startswith(f'OSwind synthetic soak {run_id} ') for n in citations)
                    if answer['provider']!='ollama' or 'Maya' not in answer['text'] or not valid or any(not w.startswith('Long sources use bounded excerpts;') for w in answer.get('warnings',[])):raise RuntimeError(f'Local answer contract failed: {answer["text"]}; {answer.get("warnings")}')
                    answer_record={'text':answer['text'],'citations':citations,'warnings':answer.get('warnings',[]),'scope':'Authored owner-string/citation contract, not semantic accuracy evaluation'}
                    answer_seconds=time.monotonic()-before;status['answers']+=1;next_chat=wall-started+a.chat_every
                resource=subprocess.check_output(['ps','-p',str(client.process.pid),'-o','rss=,%cpu='],text=True).strip().split()
                sample={'cycle':iteration,'elapsed_wall_seconds':time.time()-started,'cycle_seconds':time.monotonic()-cycle_started,'source_count':stats['count'],'disk_bytes':stats['bytes'],'mcp_rss_bytes':int(resource[0])*1024,'mcp_lifetime_cpu_percent':float(resource[1]),'answer_seconds':answer_seconds,'answer':answer_record,'writer_live_during_stats':live_before and live_after}
                samples.write(json.dumps(sample)+'\n');iteration+=1
                status.update(cycles=iteration,elapsed_wall_seconds=sample['elapsed_wall_seconds'],last_sample=sample,peak_sampled_mcp_rss_bytes=max(status.get('peak_sampled_mcp_rss_bytes',0),sample['mcp_rss_bytes']))
                atomic(root/'status.json',status)
                time.sleep(max(0,min(a.interval-(time.monotonic()-cycle_started),a.seconds-(time.time()-started))))
        status['elapsed_wall_seconds']=time.time()-started
        status['state']='completed_with_gaps' if status['oversize_wall_gaps'] else 'passed';exit_code=3 if status['oversize_wall_gaps'] else 0
    except BaseException as error:
        status['state']='interrupted' if isinstance(error,KeyboardInterrupt) else 'failed';exit_code=130 if isinstance(error,KeyboardInterrupt) else 1;status['error']=f'{type(error).__name__}: {error}'
    finally:
        if client:
            status['mcp_shutdown']=client.close()
            if status['mcp_shutdown']['forced'] or status['mcp_shutdown']['exit_code']!=0:
                status['shutdown_error']='Persistent MCP did not stop normally'
                if status['state']!='interrupted':status['state']='failed';exit_code=1
        signal.signal(signal.SIGTERM,previous_termination)
        if log:log.close()
        status['finished_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat();atomic(root/'status.json',status)
    print(json.dumps(status,indent=2),flush=True);return exit_code

if __name__=='__main__':sys.exit(main())
