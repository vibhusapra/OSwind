#!/usr/bin/env python3
"""Bounded optional macmon system telemetry. No root, service or app attribution."""
from datetime import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import threading
import time

PINNED_BINARY_SHA256='57259ce6845d0904be247c8e860fcc923300bab52e28a01f476c22c852051286'
FIELDS=('cpu_power','gpu_power','ane_power','all_power','sys_power','ram_power','gpu_ram_power','cpu_active_ratio','cpu_scaled_ratio','gpu_active_ratio')


class TelemetryError(RuntimeError):
    pass


def sample(value):
    """Whitelist numeric system fields; never persist arbitrary future fields."""
    if not isinstance(value,dict):raise TelemetryError('Expected system telemetry object')
    try:
        result={key:value[key] for key in FIELDS}
        if any(type(x) not in [int,float] or not math.isfinite(x) or x<0 for x in result.values()):
            raise ValueError('Invalid numeric measurement')
        stamp=value['timestamp']
        if not isinstance(stamp,str) or len(stamp)>64:raise ValueError('Invalid timestamp')
        instant=datetime.fromisoformat(stamp.replace('Z','+00:00'))
        if instant.utcoffset() is None:raise ValueError('Timestamp needs timezone')
        result['timestamp']=stamp
        return result
    except (KeyError,ValueError,TypeError,OverflowError):
        raise TelemetryError('Missing or invalid telemetry fields') from None


def capture(executable,*,samples=10,interval=1000,expected_sha256=PINNED_BINARY_SHA256):
    """Capture finite JSON samples and reap only the explicitly selected child.

    Power is system sensor/counter output. Zero is retained as zero, without
    implying channel availability; this does not establish process energy.
    """
    executable=Path(executable)
    if not executable.is_absolute() or not executable.is_file() or not os.access(executable,os.X_OK):
        raise ValueError('Use an explicit absolute telemetry executable')
    if type(samples) is not int or not 1<=samples<=600 or type(interval) is not int or not 100<=interval<=10000:
        raise ValueError('Use 1–600 samples and a 100–10000 ms interval')
    with executable.open('rb') as stream:
        data=stream.read(16*1024*1024+1)
    digest=hashlib.sha256(data).hexdigest()
    if len(data)>16*1024*1024 or digest!=expected_sha256:raise ValueError('Telemetry executable differs from explicit pinned hash')
    env=os.environ.copy();env.pop('MACMON_FORCE_CLPC',None)
    begin=time.monotonic();wall=time.time();deadline=begin+samples*interval/1000+15
    child=subprocess.Popen([str(executable),'--interval',str(interval),'pipe','--samples',str(samples)],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=env,bufsize=0)
    rows=[];buffer=bytearray();total=0;status=None;usage=None
    try:
        fd=child.stdout.fileno();os.set_blocking(fd,False)
        while True:
            remaining=deadline-time.monotonic()
            if remaining<=0:raise TelemetryError('Telemetry sampling exceeded its deadline')
            if not select.select([fd],[],[],min(remaining,1))[0]:continue
            try:chunk=os.read(fd,65536)
            except BlockingIOError:continue
            if not chunk:break
            total+=len(chunk)
            if total>16*1024*1024:raise TelemetryError('Telemetry exceeds16MiB')
            buffer.extend(chunk)
            while b'\n' in buffer:
                line,_,rest=buffer.partition(b'\n');buffer=bytearray(rest)
                if len(line)>256*1024 or len(rows)>=samples:raise TelemetryError('Telemetry line/count bound exceeded')
                try:value=json.loads(line)
                except (ValueError,RecursionError):raise TelemetryError('Invalid telemetry JSON') from None
                row=sample(value)
                if rows and datetime.fromisoformat(row['timestamp'].replace('Z','+00:00'))<=datetime.fromisoformat(rows[-1]['timestamp'].replace('Z','+00:00')):
                    raise TelemetryError('Telemetry timestamps are not increasing')
                row.update(awakeArrival=time.monotonic()-begin,systemArrival=time.time()-wall)
                rows.append(row)
            if len(buffer)>256*1024:raise TelemetryError('Telemetry line bound exceeded')
        if buffer:raise TelemetryError('Telemetry ended with a partial line')
        while time.monotonic()<deadline:
            pid,status,usage=os.wait4(child.pid,os.WNOHANG)
            if pid:child.returncode=os.waitstatus_to_exitcode(status);break
            time.sleep(.02)
        if child.returncode is None:raise TelemetryError('Telemetry child did not exit')
        if child.returncode!=0 or len(rows)!=samples:raise TelemetryError('Telemetry child failed or sample count incomplete')
        stamps=[datetime.fromisoformat(row['timestamp'].replace('Z','+00:00')).timestamp() for row in rows]
        gaps=[b-a for a,b in zip(stamps,stamps[1:])]
        return dict(format='OSwind finite system telemetry v1',samples=rows,samplerSHA256=digest,requestedSamples=samples,intervalMilliseconds=interval,awakeElapsedSeconds=time.monotonic()-begin,systemElapsedSeconds=time.time()-wall,childCPUSeconds=usage.ru_utime+usage.ru_stime,childMaximumResidentBytes=usage.ru_maxrss,maximumSampleGapSeconds=max(gaps) if gaps else None,maximumArrivalClockDivergenceSeconds=max(abs(row['awakeArrival']-row['systemArrival']) for row in rows),scope='System IOReport/SMC estimates from optional pinned macmon. No app-attributed energy, calibrated wall-plug power, battery budget or background-capture result.')
    finally:
        if child.returncode is None:
            previous=signal.signal(signal.SIGINT,signal.SIG_IGN) if threading.current_thread() is threading.main_thread() else None
            try:
                for native_signal,budget in [(signal.SIGTERM,2),(signal.SIGKILL,2)]:
                    try:os.kill(child.pid,native_signal)
                    except ProcessLookupError:pass
                    until=time.monotonic()+budget
                    while time.monotonic()<until:
                        pid,status,_=os.wait4(child.pid,os.WNOHANG)
                        if pid:child.returncode=os.waitstatus_to_exitcode(status);break
                        time.sleep(.02)
                    if child.returncode is not None:break
                if child.returncode is None:
                    _,status,_=os.wait4(child.pid,0);child.returncode=os.waitstatus_to_exitcode(status)
            finally:
                if previous is not None:signal.signal(signal.SIGINT,previous)
        child.stdout.close()


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sampler',type=Path,required=True)
    parser.add_argument('--samples',type=int,default=10)
    parser.add_argument('--interval',type=int,default=1000)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if sys.platform!='darwin':parser.error('The pinned sampler and RSS units require macOS')
    if args.output.exists():parser.error('Output must be new')
    report=capture(args.sampler,samples=args.samples,interval=args.interval)
    descriptor=os.open(args.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(descriptor,'w') as stream:json.dump(report,stream,indent=2,allow_nan=False);stream.write('\n')
    print(json.dumps(dict(samples=len(report['samples']),awakeElapsedSeconds=report['awakeElapsedSeconds'],systemEstimatesOnly=True)))
