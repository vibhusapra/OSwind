"""Bounded text collection through the explicit local OSwind CLI stdin contract."""
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import re
import select
import subprocess
import time
from urllib.parse import urlsplit
from . import OSwindError, _stop

MAX_BATCH_BYTES = 16 * 1024 * 1024


def _text(value, limit, *, metadata=False, empty=False):
    if not isinstance(value, str) or (not value and not empty) or len(value) > limit:
        raise ValueError("Collector field exceeds its text bound")
    try:
        size = len(value.encode('utf-8'))
    except UnicodeEncodeError:
        raise ValueError("Collector fields need valid Unicode") from None
    if size > limit or '\0' in value or (metadata and any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in value)):
        raise ValueError("Collector field has invalid size or controls")
    return value


@dataclass(frozen=True)
class Record:
    key: str
    timestamp: datetime
    app: str
    bundle_id: str
    title: str
    text: str
    url: str | None = None

    def payload(self):
        _text(self.key, 512, metadata=True)
        _text(self.app, 128, metadata=True)
        _text(self.bundle_id, 255, metadata=True)
        _text(self.title, 4096, metadata=True, empty=True)
        _text(self.text, 1024 * 1024)
        if not isinstance(self.timestamp, datetime) or self.timestamp.utcoffset() is None:
            raise ValueError("Use a timezone-aware collector timestamp")
        result = dict(key=self.key, timestamp=self.timestamp.astimezone(timezone.utc).isoformat(timespec='microseconds').replace('+00:00','Z'),
                      app=self.app, bundleID=self.bundle_id, title=self.title, text=self.text)
        if self.url is not None:
            _text(self.url, 8192, metadata=True)
            try:
                url=urlsplit(self.url)
                valid=url.scheme in ('http','https') and url.hostname and url.username is None and url.password is None and self.url == self.url.strip()
            except ValueError:
                valid=False
            if not valid:
                raise ValueError("Use a complete HTTP(S) collector source URL without credentials")
            result['url']=self.url
        return result


class Batch:
    def __init__(self, collector_id, records):
        _text(collector_id,120,metadata=True)
        parts=collector_id.split('.')
        if len(parts)<2 or not all(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?',p) for p in parts):
            raise ValueError("Use a lowercase reverse-DNS collector identity")
        self.collector_id=collector_id
        self.records=tuple(itertools.islice(records,1001))
        if not 1<=len(self.records)<=1000 or not all(isinstance(r,Record) for r in self.records):
            raise ValueError("Use one to 1000 typed collector records")
        payloads=[r.payload() for r in self.records]
        self.ids=tuple('collector:'+collector_id+':'+hashlib.sha256(r['key'].encode('utf-8')).hexdigest() for r in payloads)
        if len(set(self.ids))!=len(self.ids):
            raise ValueError("Collector source keys must be unique within a batch")
        self._payload=dict(format='OSwind collector batch',version=1,collectorID=collector_id,records=payloads)

    @property
    def tag(self):
        return 'collector:'+hashlib.sha256(self.collector_id.encode('ascii')).hexdigest()[:32]

    def encode(self):
        output=bytearray()
        encoder=json.JSONEncoder(ensure_ascii=False,allow_nan=False,separators=(',',':'))
        for chunk in encoder.iterencode(self._payload):
            data=chunk.encode('utf-8')
            if len(output)+len(data)+1>MAX_BATCH_BYTES:
                raise ValueError("Collector batch exceeds 16 MiB")
            output.extend(data)
        output.extend(b'\n')
        return bytes(output)


def submit(executable, data, batch, *, timeout=30.0):
    """Send one batch to explicit CLI stdin, with bounded I/O and owned child.

    Failed/timeout responses leave result unconfirmed: the atomic commit might
    have completed. Retry identical stable keys. No payload argv/staging files.
    """
    executable,data=Path(executable),Path(data)
    if not executable.is_absolute() or not executable.is_file() or not os.access(executable,os.X_OK) or not data.is_absolute() or not data.exists():
        raise ValueError("Use an explicit executable and existing absolute library path")
    if not isinstance(batch,Batch) or not math.isfinite(timeout) or not 0<timeout<=300:
        raise ValueError("Use a typed batch and timeout from zero to 300 seconds, excluding zero")
    payload=batch.encode()  # Validate before starting any process.
    process=subprocess.Popen([str(executable),'--data',str(data),'collect','--stdin'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,bufsize=0,close_fds=True)
    deadline=time.monotonic()+timeout;output=bytearray();offset=0;input_open=True
    try:
        input_fd,output_fd=process.stdin.fileno(),process.stdout.fileno()
        os.set_blocking(input_fd,False);os.set_blocking(output_fd,False)
        while True:
            remaining=deadline-time.monotonic()
            if remaining<=0:raise OSwindError("Collector result is unconfirmed after timeout; retry identical keys")
            readable,writable,_=select.select([output_fd],[input_fd] if input_open else [],[],remaining)
            if writable:
                try:written=os.write(input_fd,payload[offset:offset+65536])
                except BlockingIOError:continue
                if not written:raise OSwindError("Collector request stream closed")
                offset+=written
                if offset==len(payload):process.stdin.close();input_open=False
            if readable:
                try:chunk=os.read(output_fd,65536)
                except BlockingIOError:continue
                if not chunk:break
                if len(output)+len(chunk)>1024*1024:raise OSwindError("Collector report exceeds 1 MiB")
                output.extend(chunk)
        if offset!=len(payload) or process.wait(timeout=max(.001,deadline-time.monotonic()))!=0:
            raise OSwindError("Collector result is unconfirmed; retry identical keys")
        report=json.loads(output)
        if (not isinstance(report,dict) or report.get('format')!='OSwind collector result'
            or type(report.get('version')) is not int or report['version']!=1
            or report.get('collectorID')!=batch.collector_id
            or report.get('sourceIDs')!=list(batch.ids)
            or type(report.get('requested')) is not int or report['requested']!=len(batch.ids)
            or any(type(report.get(k)) is not int or report[k]<0 for k in ('imported','excluded'))
            or report['imported']+report['excluded']!=report['requested']):
            raise OSwindError("Collector report identity or counts are invalid; result is unconfirmed")
        return report
    except (OSError,ValueError,RecursionError,subprocess.TimeoutExpired):
        raise OSwindError("Collector result is unconfirmed; retry identical keys") from None
    finally:
        _stop(process)
