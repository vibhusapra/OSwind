#!/usr/bin/env python3
"""Prepare a new private output directory for the authored XCTest probe only."""
import argparse,json,os,pathlib,uuid

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('output',type=pathlib.Path);args=parser.parse_args();p=args.output
 if not p.is_absolute() or p.resolve()!=p or not p.parent.is_dir():parser.error('Output must be a new absolute nonsymlink path with an existing parent')
 try:p.mkdir(mode=0o700)
 except FileExistsError:parser.error('Refusing an existing output directory')
 marker=dict(kind='OSwind authored indexed retrieval probe v1',nonce=str(uuid.uuid4()),uid=os.getuid())
 descriptor=os.open(p/'owned-probe.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
 with os.fdopen(descriptor,'w') as f:json.dump(marker,f,sort_keys=True);f.write('\n')
 print(json.dumps(dict(state='prepared',output=str(p))))

if __name__=='__main__':main()
