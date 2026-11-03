#!/usr/bin/env python3
"""Review a retained authored offline CLI archive without executing either product."""
import argparse, collections, hashlib, json, math, statistics, zipfile
from pathlib import Path

PRODUCTS = ('oswind-baseline', 'oswind', 'screenpipe')
CASES = ('rare-first','rare-991','rare-last','absent','broad','app-present','app-absent','time-present','time-absent')
PINNED_SOURCES = ('7c0292bac86543b4c8c58eae2a7f109b9a3ba0c3','f4cff25d88d0f07b8d24b69ed44fba065aa19464')
PINS = {'oswind-baseline':'f72d02299cef0a65c789612ab124d13b82fea2f5f462c6fe8931a7ac7036f7bf','oswind':'0e5a0fd3873f5ecfd3e3a91e6612df037e1acdcf2e7fbdf8c42f42a04b60dd37','screenpipe':'49aab1665e03da5366314ad859c695958b17970414ae18f1dabad65e9451f3a8'}

def require(condition, message):
    if not condition: raise ValueError(message)

def sha(data): return hashlib.sha256(data).hexdigest()

def validate_output(data, product, rows, case):
    text=data.decode('utf-8')
    hits=[json.loads(line) for line in text.splitlines() if line.strip()] if product=='screenpipe' else json.loads(text)
    require(isinstance(hits,list),'Expected result list')
    ids=[]
    for hit in hits:
        if product=='screenpipe':
            require(hit['type']=='OCR','Unexpected source type'); d=hit['content']; identifier=d['frame_name']; body=d['text']; app=d['app_name']; title=d['window_name']
        else:
            require(hit['match']=='keyword' and math.isfinite(hit['score']),'Invalid keyword score');d=hit['memory'];identifier=d['id'];body=d['text'];app=d['app'];title=d['title']
        require(identifier.startswith('scale-') and identifier[6:].isdigit(),'Invalid ID')
        n=int(identifier[6:]);require(1<=n<=rows and identifier=='scale-'+str(n),'Invalid authored membership')
        require(body=='Owned source '+str(n) and app=='Owned capture scale' and title=='Scale record' and d['timestamp']=='2023-11-14T22:13:20Z','Original fields differ')
        ids.append(identifier)
    require(len(ids)==len(set(ids)),'Duplicate result')
    expected={'rare-first':['scale-1'],'rare-991':['scale-991'],'rare-last':['scale-'+str(rows)],'absent':[],'app-present':['scale-991'],'app-absent':[],'time-present':['scale-991'],'time-absent':[]}
    require(len(ids)==100 if case=='broad' else ids==expected[case],'Result membership differs')
    return ids

def review(read):
    r=json.loads(read('report.json'))
    require((r['oswindBaselineSource'],r['oswindSource'])==PINNED_SOURCES,'Unexpected sources')
    require(r['binaryPins']=={k:PINS[k] for k in ('oswind','screenpipe')} and r['oswindBaselineBinarySHA256']==PINS['oswind-baseline'],'Unexpected executable pins')
    require(sha(read('measure-keyword-v3.py'))==r['harnessSHA256'],'Harness hash mismatch')
    require(r['repetitions']==21 and len(r['measurements'])==1134 and len(r['warmups'])==54,'Incomplete observations')
    seen=set(); paired={}; measured=collections.defaultdict(list)
    for warm,records in ((False,r['measurements']),(True,r['warmups'])):
        for m in records:
            rows,case,iteration,product=(m[k] for k in ('rows','case','iteration','product'))
            require(rows in (1000,100000) and case in CASES and product in PRODUCTS,'Unexpected observation')
            require(iteration=='warm' if warm else type(iteration) is int and 0<=iteration<21,'Invalid round')
            key=(rows,case,iteration,product);require(key not in seen,'Duplicate observation');seen.add(key)
            stem=f'{rows}-{case}-{iteration}-{product}';out=read(stem+'.stdout');err=read(stem+'.stderr')
            require(sha(out)==m['stdoutSHA256'] and sha(err)==m['stderrSHA256'] and not err,'Output hash/stderr mismatch')
            require(len(out)==m['stdoutBytes'] and validate_output(out,product,rows,case)==m['returnedIDs'],'Output fields mismatch')
            for field in ('wallMS','userCPUSeconds','systemCPUSeconds','peakRSSBytes','stdoutBytes'):
                value=m[field];require(type(value) in (int,float) and math.isfinite(value) and value>=0,'Invalid metric')
            paired[(rows,case,iteration,product)]=out
            if not warm: measured[(rows,case,product)].append(m)
    require(len(seen)==1188,'Missing observations')
    for rows in (1000,100000):
        for case in CASES:
            for iteration in ['warm',*range(21)]:
                require(paired[(rows,case,iteration,'oswind')]==paired[(rows,case,iteration,'oswind-baseline')],'Changed OSwind output')
    require(len(r['summaries'])==18,'Incomplete summaries'); summary_seen=set()
    for summary in r['summaries']:
        key=(summary['rows'],summary['case']);require(key not in summary_seen,'Duplicate summary');summary_seen.add(key)
        require(set(summary['products'])==set(PRODUCTS),'Incomplete summary products')
        for product in PRODUCTS:
            for field in ('wallMS','userCPUSeconds','systemCPUSeconds','peakRSSBytes','stdoutBytes'):
                values=sorted(m[field] for m in measured[(*key,product)])
                expected=dict(samples=21,median=statistics.median(values),p95=values[math.ceil(.95*21)-1])
                require(summary['products'][product][field]==expected,'Summary metric differs')
    return dict(format='OSwind offline keyword archive review v1',validatedMeasurements=1134,validatedWarmups=54,byteIdenticalOSwindPairs=396,summaryGroups=18,scope='Authored offline CLI component only; no energy, capture, semantic-quality or product ranking claim.')

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('archive',type=Path);a=p.parse_args()
    with zipfile.ZipFile(a.archive) as z:
        names=z.namelist();require(len(names)==len(set(names)),'Duplicate archive names')
        require(all(not n.startswith('/') and '..' not in Path(n).parts and z.getinfo(n).file_size<10_000_000 for n in names),'Unsafe archive entry')
        result=review(z.read)
    result['archiveSHA256']=sha(a.archive.read_bytes());print(json.dumps(result,indent=2))

if __name__=='__main__':main()
