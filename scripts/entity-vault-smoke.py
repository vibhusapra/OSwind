#!/usr/bin/env python3
"""Owned entity metadata on an actual encrypted APFS library; no user auth/keys."""
import argparse,hashlib,json,pathlib,plistlib,secrets,subprocess
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary',type=pathlib.Path);p.add_argument('--root',required=True,type=pathlib.Path);a=p.parse_args()
binary=a.binary.resolve();root=a.root.resolve();root.mkdir(mode=0o700,exist_ok=False)
package=root/'Owned.oswindvault';secret=secrets.token_urlsafe(32).encode()
report=dict(format='OSwind native entity vault v1',state='running',binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),checks=[],scope='Synthetic source and entity metadata on one newly-created encrypted APFS volume. No normal library, real credentials, Keychain, authentication or TCC changes. No Apple-framework temporary-memory zeroization or power claim.')
def save():(root/'report.json').write_text(json.dumps(report,indent=2)+'\n')
def command(*args,password=None):
    result=subprocess.run([str(binary),*map(str,args)],input=secret+b'\0' if password else b'',capture_output=True,timeout=120)
    assert secret not in result.stdout and secret not in result.stderr
    assert result.returncode==0,result.stderr.decode(errors='replace');return result.stdout.decode()
def entity(*args):return json.loads(command('--vault',package,'entity',*args))
def attached():
    info=plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil','info','-plist']))
    return [image for image in info.get('images',[]) if image.get('image-path','').startswith(str(root)+'/')]
save()
try:
    assert json.loads(command('vault','create',package,'--name','Owned entity fixture','--capacity-gb','1','--passphrase-stdin',password=True))['state']=='locked'
    assert not attached()
    command('vault','unlock',package,'--passphrase-stdin',password=True)
    source=command('--vault',package,'note','Owned encrypted project notes for Apollo Launch.').strip()
    project=entity('create','project','Apollo Launch','--notes','Explicit synthetic project note')
    assert entity('index')['indexed']==1
    links=entity('sources',project['id']);assert len(links)==1 and links[0]['surface']=='Apollo Launch'
    person=entity('create','person','Synthetic reviewer');entity('link',person['id'],source)
    report['checks'].append('native local NLP/project indexing and explicit person link on verified encrypted library')
    entity('unlink',project['id'],source)
    entity('edit',project['id'],'--aliases','Apollo Launch,Owned alias')
    assert entity('index')['indexed']==1 and entity('sources',project['id'])==[]
    report['checks'].append('rejected project mention survives native encrypted rule-rescan')
    locked=json.loads(command('vault','lock',package));assert locked['state']=='locked' and not attached()
    command('vault','unlock',package,'--passphrase-stdin',password=True)
    groups=entity('list');assert next(g for g in groups if g['id']==project['id'])['detail']=='Explicit synthetic project note'
    assert entity('sources',project['id'])==[] and entity('sources',person['id'])[0]['id']==source
    report['checks'].append('labels, notes, correction and deliberate source link survive normal lock/remount')
    archive=root/'entity.oswindbackup';restored=root/'restored'
    info=json.loads(command('--vault',package,'backup','create',archive));assert info['sourceSchema']==22
    command('backup','restore',archive,'--to',restored)
    restored_groups=json.loads(command('--data',restored,'entity','list'));assert {g['id'] for g in restored_groups}=={g['id'] for g in groups}
    assert json.loads(command('--data',restored,'entity','index'))['indexed']==1
    assert json.loads(command('--data',restored,'entity','sources',project['id']))==[]
    assert json.loads(command('--data',restored,'entity','sources',person['id']))[0]['id']==source
    report['checks'].append('full backup and quiet restore retain entity metadata/correction with native rescan')
    locked=json.loads(command('vault','lock',package));assert locked['state']=='locked' and not attached()
    report.update(state='completed',schema=info['sourceSchema'],sourceCount=1,entityCount=len(groups),verifiedDetached=True,passphrasePersisted=False)
except BaseException as error:report.update(state='failed',failure=str(error));raise
finally:
    try:
        if attached():command('vault','lock',package)
        report['cleanupDetached']=not bool(attached())
    except BaseException as error:report['cleanupFailure']=str(error)
    save()
print(json.dumps(report,indent=2))
