#!/usr/bin/env python3
"""Native model CLI contracts and real public-download interruption recovery.

An existing pinned Parakeet install is cloned only for the recovery verification;
full-model network downloads are not required by the interruption cases.
"""
import argparse,hashlib,json,os,pathlib,shutil,signal,subprocess,tempfile,time
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary');p.add_argument('--installed-model',required=True);p.add_argument('--output',required=True);a=p.parse_args()
binary=pathlib.Path(a.binary).resolve();installed=pathlib.Path(a.installed_model).resolve()
report={'scope':'native model CLI graceful SIGINT, SIGKILL lease recovery and verified reuse; public pinned model requests only','checks':[],'limits':['public network/CDN timing is uncontrolled','not capture, inference, power or competitor performance','recovery uses a complete pinned model copied into the expected destination after the killed partial job']}
with tempfile.TemporaryDirectory(prefix='oswind-native-model-process-') as temporary:
    root=pathlib.Path(temporary);forbidden=root/'must-not-create-library';cache=root/'models';cache.mkdir(mode=0o700)
    def run(*args):return subprocess.run([str(binary),'--data',str(forbidden),'native-model',*map(str,args)],capture_output=True,text=True,timeout=60)
    listed=run('list','--cache-root',cache);assert listed.returncode==0
    catalogs=json.loads(listed.stdout);name=pathlib.Path(next(x['directory'] for x in catalogs if x['kind']=='parakeet')).name
    missing=run('verify','parakeet','--cache-root',cache);assert missing.returncode!=0 and not forbidden.exists()
    report['checks'].append({'case':'catalog and missing verification','memory_library_created':False,'network_required':False})
    def active_download(tag):
        log=root/(tag+'.log');output=root/(tag+'.json');logfile=log.open('w');stdout=output.open('w')
        process=subprocess.Popen([str(binary),'--data',str(forbidden),'native-model','install','parakeet','--cache-root',str(cache)],stdout=stdout,stderr=logfile)
        deadline=time.monotonic()+90;stage=None;partial=0
        try:
            while time.monotonic()<deadline and process.poll() is None:
                stages=list(cache.glob('.oswind-model-download-*'))
                if stages:
                    stage=stages[0];partial=sum(f.stat().st_size for f in stage.rglob('*') if f.is_file())
                    if partial>=1024*1024:break
                time.sleep(.02)
            assert process.poll() is None and stage and partial>=1024*1024,(tag,process.poll(),log.read_text()[-1000:])
            return process,stage,partial,logfile,stdout
        except BaseException:
            if process.poll() is None:process.kill()
            process.wait();logfile.close();stdout.close();raise
    process,stage,partial,log,stdout=active_download('interrupt')
    try:
        started=time.perf_counter();process.send_signal(signal.SIGINT);code=process.wait(timeout=20);elapsed=time.perf_counter()-started
        assert code==130,(code,stage);assert not list(cache.iterdir()),list(cache.iterdir())
        report['checks'].append({'case':'graceful SIGINT after real streamed bytes','received_stage_bytes_at_signal':partial,'exit':code,'seconds_to_exit':elapsed,'staging_and_leases_removed':True})
    finally:
        if process.poll() is None:process.kill();process.wait()
        log.close();stdout.close()
    process,stage,partial,log,stdout=active_download('killed')
    try:process.kill();code=process.wait(timeout=20)
    finally:
        if process.poll() is None:process.kill();process.wait()
        log.close();stdout.close()
    assert code==-signal.SIGKILL and stage.exists();old=set(p.name for p in cache.iterdir())
    target=cache/name
    cloned=subprocess.run(['cp','-cR',str(installed),str(target)],capture_output=True,text=True)
    method='APFS clone'
    if cloned.returncode:
        if target.exists():shutil.rmtree(target)
        shutil.copytree(installed,target);method='streamed filesystem copy'
    recovered=run('install','parakeet','--cache-root',cache);assert recovered.returncode==0,recovered.stderr
    value=json.loads(recovered.stdout);assert value['reused'] and value['files']==22 and value['bytes']==483106120
    assert not any((cache/name).exists() for name in old);assert sorted(x.name for x in cache.iterdir())==[target.name]
    assert not forbidden.exists()
    report['checks'].append({'case':'SIGKILL partial then next install recovers lease and verifies an existing complete model','received_stage_bytes_at_kill':partial,'killed_exit':code,'complete_model_source':method,'orphan_staging_removed':True,'verified_reuse':True,'memory_library_created':False})
report['passed']=True;report['binary_sha256']=hashlib.sha256(binary.read_bytes()).hexdigest();pathlib.Path(a.output).write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
