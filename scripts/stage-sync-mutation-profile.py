#!/usr/bin/env python3
"""Build and pin a fresh owned optimized XCTest profile."""
import argparse,datetime,hashlib,json,os,pathlib,shutil,subprocess,sys
parser=argparse.ArgumentParser(description="Stage an optimized sync benchmark payload from this checkout; never switches source files.")
parser.add_argument('root',type=pathlib.Path);parser.add_argument('profile',choices=['baseline','candidate']);a=parser.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1];os.chdir(repo);root=a.root.absolute();assert root.resolve()==root and root.is_dir() and not root.is_symlink()
assert (root/'owned-fixture').read_bytes()==b'OSwind authored sync mutation profiles v1'
profile=a.profile;base=root/profile
assert not base.exists();base.mkdir(mode=0o700)
def sha(p):
 with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def snapshot(root):return {str(p.relative_to(root)):sha(p) for p in root.rglob('*') if p.is_file() and '.git' not in p.parts and '__pycache__' not in p.parts}
frozen={}
for directory in ['Sources','Tests','Vendor','scripts','models','ThirdParty','assets','sdk','.github']:
 for p in (repo/directory).rglob('*'):
  if p.is_file() and '__pycache__' not in p.parts and not p.name.endswith(('.sqlite-wal','.sqlite-shm')):frozen[str(p.relative_to(repo))]=sha(p)
for p in [repo/'Package.swift',repo/'Package.resolved',pathlib.Path(__file__).resolve()]:frozen[str(p.relative_to(repo))]=sha(p)
if profile=='baseline':assert not subprocess.check_output(['git','diff','--name-only','--','Sources','Vendor']).strip()
for name,h in frozen.items():
 if not name.startswith('.artifacts/'):
  source=repo/name;target=base/'frozen-inputs'/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target);assert sha(target)==h
(base/'inputs.json').write_text(json.dumps(frozen,indent=2)+'\n');dependencies=snapshot(repo/'.build/checkouts');(base/'dependencies.json').write_text(json.dumps(dependencies,indent=2)+'\n')
report=dict(state='building',profile=profile,sourceBase=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),startedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),frozenInputs=len(frozen),sourceInputsSHA256=sha(base/'inputs.json'),dependencyInputsSHA256=sha(base/'dependencies.json'))
(base/'build.json').write_text(json.dumps(report,indent=2)+'\n')
log=base/'build.log'
with log.open('wb') as out:
 child=subprocess.Popen(['swift','test','-c','release','--filter','SyncIncomingSourceTests.testDerivedRetirementSourceUpdateRetiresReceiverMentionAndPreservesDefinition'],stdout=out,stderr=subprocess.STDOUT);report['pid']=child.pid;(base/'build.json').write_text(json.dumps(report,indent=2)+'\n');status=child.wait()
for p,h in frozen.items():assert sha(repo/p)==h,p
assert snapshot(repo/'.build/checkouts')==dependencies
report.update(returncode=status,logSHA256=sha(log),inputsUnchanged=True,finishedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat())
if status:report['state']='failed';(base/'build.json').write_text(json.dumps(report,indent=2)+'\n');raise SystemExit(status)
source=(repo/'.build/release/OSwindPackageTests.xctest').resolve();target=base/'payload/OSwindPackageTests.xctest';target.parent.mkdir(mode=0o700);shutil.copytree(source,target)
assert not any(p.is_symlink() for p in target.rglob('*'))
files=snapshot(target);(base/'payload.json').write_text(json.dumps(files,indent=2)+'\n')
binary=target/'Contents/MacOS/OSwindPackageTests';dependencies_text=subprocess.check_output(['xcrun','otool','-L',str(binary)],text=True);(base/'macho-dependencies.txt').write_text(dependencies_text)
for line in dependencies_text.splitlines()[1:]:
 path=line.strip().split(' (')[0]
 assert path.startswith(('/System/Library/','/usr/lib/')) or path in ['@rpath/Testing.framework/Versions/A/Testing','@rpath/libXCTestSwiftSupport.dylib','@rpath/libswiftCompatibilitySpan.dylib'],path
report.update(state='built',payload=str(target.relative_to(repo)),payloadManifestSHA256=sha(base/'payload.json'),executableSHA256=sha(binary),systemAndXCTestLinkageOnly=True)
(base/'build.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
