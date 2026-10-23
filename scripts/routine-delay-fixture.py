#!/usr/bin/env python3
"""Loopback-only native Cancel-button fixture, for isolated synthetic libraries.
/api/show|tags|ps proxy local model metadata only. /api/chat never forwards
context: it waits then returns an explicitly synthetic reply. No keys/cookies,
source text or request bodies are logged. Not a product server or AI benchmark.
"""
import argparse,http.server,json,os,pathlib,signal,threading,time,urllib.request
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--port',type=int,default=47834);p.add_argument('--delay',type=float,default=20);p.add_argument('--status',type=pathlib.Path,required=True);a=p.parse_args()
assert 1024<=a.port<=65535 and 5<=a.delay<=120
assert not a.status.exists();a.status.parent.mkdir(parents=True,exist_ok=True)
state={'scope':'Synthetic loopback delayed transport fixture; not actual chat inference','pid':os.getpid(),'port':a.port,'delay_seconds':a.delay,'state':'starting','requests':[],'chat_started':0,'reply_sent':0,'client_disconnected':0};lock=threading.Lock()
def update(**values):
 with lock:
  state.update(values);temporary=a.status.with_suffix('.part')
  with temporary.open('w') as out:os.chmod(temporary,0o600);json.dump(state,out,indent=2)
  temporary.replace(a.status)
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def respond(self,status,body):
  self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
 def handle_request(self):
  if self.headers.get('Origin') or self.headers.get('Host') not in [f'127.0.0.1:{a.port}',f'localhost:{a.port}']:self.respond(403,b'{}');return
  size=int(self.headers.get('Content-Length','0'))
  if not 0<=size<=1048576:self.respond(413,b'{}');return
  body=self.rfile.read(size)
  with lock:state['requests'].append({'method':self.command,'path':self.path})
  update()
  if self.command=='POST' and self.path=='/api/chat':
   update(chat_started=state['chat_started']+1);time.sleep(a.delay)
   try:
    self.respond(200,json.dumps({'message':{'role':'assistant','content':'Synthetic delayed transport reply [1].'},'done':True,'done_reason':'stop'}).encode());update(reply_sent=state['reply_sent']+1)
   except (BrokenPipeError,ConnectionResetError):update(client_disconnected=state['client_disconnected']+1)
  elif (self.command,self.path) in [('POST','/api/show'),('GET','/api/tags'),('GET','/api/ps')]:
   request=urllib.request.Request('http://127.0.0.1:11434'+self.path,data=body if self.command=='POST' else None,headers={'Content-Type':'application/json'},method=self.command)
   try:
    with urllib.request.urlopen(request,timeout=15) as response:self.respond(response.status,response.read(2097152))
   except Exception:self.respond(502,b'{"error":"Local model metadata unavailable"}')
  else:self.respond(404,b'{}')
 do_POST=handle_request
 do_GET=handle_request
server=http.server.ThreadingHTTPServer(('127.0.0.1',a.port),Handler);update(state='running')
def stop(*_):raise SystemExit()
signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
try:server.serve_forever(poll_interval=.2)
finally:server.server_close();update(state='stopped')
