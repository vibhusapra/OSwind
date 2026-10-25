"""Independent entity-membership scoring; no model invocation or network."""
import hashlib,json,unicodedata

def utf16_length(text):return len(text.encode('utf-16-le'))//2
def canonical(text):return unicodedata.normalize('NFC',' '.join(text.split())).lower()
def token_spans(tokens):
 if not tokens or any(not isinstance(t,str) or not t or '\x00' in t for t in tokens):raise ValueError('Invalid token sequence')
 spans=[];offset=0
 for token in tokens:
  end=offset+utf16_length(token);spans.append((offset,end));offset=end+1
 return ' '.join(tokens),spans

def gold_memberships(record):
 tokens=record['tokens'];coarse=record['ner_tags'];fine=record['fine_ner_tags']
 if len(tokens)!=len(coarse) or len(tokens)!=len(fine):raise ValueError('Annotation length mismatch')
 text,bounds=token_spans(tokens);result={};mapped={2:'place',4:'place',5:'organization',7:'person'};i=0
 while i<len(tokens):
  if not isinstance(coarse[i],int) or not 0<=coarse[i]<=8 or not isinstance(fine[i],int) or not 0<=fine[i]<=66:raise ValueError('Unknown label')
  begin=i;i+=1
  while i<len(tokens) and coarse[i]==coarse[begin] and fine[i]==fine[begin]:i+=1
  if coarse[begin] in mapped:
   surface=' '.join(tokens[begin:i]);kind=mapped[coarse[begin]];key=(kind,canonical(surface));start=bounds[begin][0];length=bounds[i-1][1]-start
   result.setdefault(key,set()).add((start,length))
 return text,result

def metrics(tp,fp,fn):
 precision=tp/(tp+fp) if tp+fp else 0;recall=tp/(tp+fn) if tp+fn else 0
 return dict(truePositive=tp,falsePositive=fp,falseNegative=fn,precision=precision,recall=recall,F1=2*tp/(2*tp+fp+fn) if 2*tp+fp+fn else 0)

def score(records,predictions):
 ids={r['id'] for r in records}
 if len(ids)!=len(records) or any(p['source'] not in ids for p in predictions):raise ValueError('Duplicate/unknown source')
 kinds=['person','organization','place'];counts={k:[0,0,0] for k in kinds};anchored={k:[0,0,0] for k in kinds};invalid=0
 bySource={i:[] for i in ids}
 for p in predictions:bySource[p['source']].append(p)
 for r in records:
  text,gold=gold_memberships(r);encoded=text.encode('utf-16-le');pred={};validAnchor={}
  for p in bySource[r['id']]:
   if p['kind'] not in kinds:raise ValueError('Unsupported prediction kind')
   key=(p['kind'],canonical(p['surface']));start=p['start'];length=p['length']
   if key in pred:raise ValueError('Duplicate source/kind/name membership')
   if not isinstance(start,int) or not isinstance(length,int) or start<0 or length<=0 or (start+length)*2>len(encoded):valid=False
   else:
    try:valid=encoded[start*2:(start+length)*2].decode('utf-16-le')==p['surface']
    except UnicodeDecodeError:valid=False
   invalid+=not valid;pred[key]=p;validAnchor[key]=valid
  for kind in kinds:
   expected={k for k in gold if k[0]==kind};observed={k for k in pred if k[0]==kind};tp=expected&observed
   counts[kind][0]+=len(tp);counts[kind][1]+=len(observed-expected);counts[kind][2]+=len(expected-observed)
   exact={k for k in tp if validAnchor[k] and (pred[k]['start'],pred[k]['length']) in gold[k]}
   anchored[kind][0]+=len(exact);anchored[kind][1]+=len(observed-exact);anchored[kind][2]+=len(expected-exact)
 def totals(values):return metrics(*(sum(v[i] for v in values.values()) for i in range(3)))
 return dict(sources=len(records),predictions=len(predictions),invalidSourceAnchors=invalid,membership=dict(micro=totals(counts),byKind={k:metrics(*v) for k,v in counts.items()}),anchoredMembership=dict(micro=totals(anchored),byKind={k:metrics(*v) for k,v in anchored.items()}))

def select(records,split,count):
 if split not in ['validation','test'] or count<1 or count>len(records):raise ValueError('Invalid selection')
 ids=[r['id'] for r in records]
 if len(set(ids))!=len(ids):raise ValueError('Duplicate corpus ID')
 seed='OSwind Few-NERD entity membership v1/'+split+'/'
 return sorted(records,key=lambda r:(hashlib.sha256((seed+str(r['id'])).encode()).hexdigest(),str(r['id'])))[:count]

def self_test():
 r=dict(id='unicode',tokens=['😀','Maya','Chen','met','Maya','Chen','in','Paris','.'],ner_tags=[0,7,7,0,7,7,0,4,0],fine_ner_tags=[0,54,54,0,54,54,0,21,0])
 text,g=gold_memberships(r);assert text=='😀 Maya Chen met Maya Chen in Paris .';assert g[('person','maya chen')]=={(3,9),(17,9)}
 p=[dict(source='unicode',kind='person',surface='Maya Chen',start=17,length=9),dict(source='unicode',kind='place',surface='Paris',start=30,length=5)]
 s=score([r],p);assert s['membership']['micro']['F1']==1 and s['anchoredMembership']['micro']['F1']==1 and s['invalidSourceAnchors']==0
 # A correct label at a broken surrogate/incorrect source location is not anchored evidence.
 p[0]['start']=1;s=score([r],p);assert s['membership']['micro']['F1']==1 and s['anchoredMembership']['micro']['truePositive']==1 and s['invalidSourceAnchors']==1
 # Partial names are false positives and leave the full expected name missing.
 p=[dict(source='unicode',kind='person',surface='Chen',start=8,length=4)];s=score([r],p);assert s['membership']['micro']==metrics(0,1,2)
 # Adjacent different fine types retain separate boundaries after coarse projection.
 q=dict(id='adjacent',tokens=['Maya','Chen','Harbor','Tower'],ner_tags=[7,7,4,2],fine_ner_tags=[54,55,21,11]);_,g=gold_memberships(q);assert len(g)==4
 # Empty prediction is a real false negative, rather than an ignored source.
 assert score([r],[])['membership']['micro']==metrics(0,0,2)
 for bad in [p+p,[dict(source='missing',kind='person',surface='Chen',start=0,length=4)]]:
  try:score([r],bad)
  except ValueError:pass
  else:raise AssertionError('Invalid predictions accepted')
 assert select([r,q],'test',1)==select([q,r],'test',1)
 print('PASS: repeated-name membership, alternate gold anchor, UTF-16 surrogate rejection, partial names, projected boundaries, empty/unknown/duplicate sources and stable selection')

if __name__=='__main__':self_test()
