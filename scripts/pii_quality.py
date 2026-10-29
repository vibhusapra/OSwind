#!/usr/bin/env python3
"""Independent bounded span scorer for authored PII experiments.

Offsets are Unicode codepoints. This does not validate full Unicode grapheme
boundaries or implement native privacy admission; those require separate checks.
No model imports, network access or permissive missing-result handling.
"""
import hashlib,json,math,pathlib

def verify_plan(plan_path,corpus_path,root=None):
    """Reject changed code/corpus before loading any model or invoking a CLI.

    The explicit local plan is an experiment recipe, not a trust signature.
    Code entries must remain within the selected repository checkout.
    """
    root=(pathlib.Path(root) if root else pathlib.Path(__file__).resolve().parent.parent).resolve()
    plan=json.loads(pathlib.Path(plan_path).read_text())
    required={'scripts/prepare-pii-eval.py','scripts/pii_quality.py','scripts/test-pii-quality.py','scripts/evaluate-pii-model.py','scripts/evaluate-pii-baseline.py'}
    entries=plan.get('codeSHA256',{})
    if not required<=entries.keys():raise ValueError('Incomplete PII code plan')
    for name,digest in entries.items():
        relative=pathlib.Path(name);path=(root/relative).resolve()
        if relative.is_absolute() or '..' in relative.parts or not path.is_relative_to(root):raise ValueError('PII code path escapes checkout')
        if sha256(path)!=digest:raise ValueError('PII code differs: '+name)
    if sha256(corpus_path)!=plan.get('corpusSHA256'):raise ValueError('PII corpus differs')
    return plan

def sha256(path):
    with pathlib.Path(path).open('rb') as source:return hashlib.file_digest(source,'sha256').hexdigest()
def legacy_mask(text,sanitized):
    """Recover only a unique monotonic mask; never guess ambiguous offsets.

    The shipped sanitizer preserves literal text between replacement markers.
    This oracle does not copy its patterns or choose offsets from gold labels.
    """
    if text==sanitized:return []
    marker='[REDACTED]';anchors=sanitized.split(marker)
    if len(text)>4096 or not 1<len(anchors)<=9 or not text.startswith(anchors[0]):raise ValueError('Unrecoverable baseline redaction')
    answers=set();attempts=0
    def visit(index,cursor,masked):
        nonlocal attempts
        attempts+=1
        if attempts>100000:raise ValueError('Baseline alignment budget exceeded')
        anchor=anchors[index]
        if index==len(anchors)-1:
            start=len(text)-len(anchor)
            if start>cursor and text[start:]==anchor:answers.add(masked|frozenset(range(cursor,start)))
        else:
            start=cursor+1
            while start<=len(text):
                found=text.find(anchor,start)
                if found<0:break
                visit(index+1,found+len(anchor),masked|frozenset(range(cursor,found)))
                if len(answers)>1:break
                start=found+1
    visit(1,len(anchors[0]),frozenset())
    if len(answers)!=1:raise ValueError('Ambiguous baseline redaction')
    points=sorted(answers.pop());spans=[]
    for point in points:
        if spans and spans[-1]['end']==point:spans[-1]['end']+=1
        else:spans.append({'start':point,'end':point+1,'label':'pattern_redaction'})
    return spans
def utf16_range(text,start,end):
    return {'location':len(text[:start].encode('utf-16-le'))//2,'length':len(text[start:end].encode('utf-16-le'))//2}
def validate_span(text,span,labels):
    start,end=span.get('start'),span.get('end')
    if type(start) is not int or type(end) is not int or not 0<=start<end<=len(text):raise ValueError('Invalid PII source range')
    if span.get('label') not in labels:raise ValueError('Unknown PII category')
    if 'text' in span and span['text']!=text[start:end]:raise ValueError('PII source text differs')
    if 'score' in span and (type(span['score']) not in [int,float] or not math.isfinite(span['score']) or not 0<=span['score']<=1):raise ValueError('Invalid PII score')
    utf16_range(text,start,end) # Refuse invalid Unicode scalars, including surrogates.
    return (span['label'],start,end)
def scores(tp,fp,fn):
    precision=tp/(tp+fp) if tp+fp else 0;recall=tp/(tp+fn) if tp+fn else 0
    return {'tp':tp,'fp':fp,'fn':fn,'precision':precision,'recall':recall,'f1':2*precision*recall/(precision+recall) if precision+recall else 0}
def evaluate(rows,results,labels):
    if len(rows)>10000 or len(results)!=len(rows):raise ValueError('Missing/extra PII result')
    expected={r['id']:r for r in rows};actual={r['id']:r for r in results}
    if len(expected)!=len(rows) or len(actual)!=len(results) or expected.keys()!=actual.keys():raise ValueError('Duplicate or mismatched source identity')
    tp=fp=fn=char_tp=char_fp=char_fn=negative=negative_fp=values=covered=0;per_label={k:[0,0,0] for k in labels}
    for id,row in expected.items():
        text=row['text'];predicted=actual[id]
        if not isinstance(text,str) or len(text)>4096 or not isinstance(row['gold'],list) or len(row['gold'])>1000:raise ValueError('PII source exceeds scorer bound')
        if predicted.get('sourceSHA256')!=hashlib.sha256(text.encode()).hexdigest():raise ValueError('Changed PII source')
        spans=predicted.get('spans')
        if not isinstance(spans,list) or len(spans)>1000:raise ValueError('Invalid PII result collection')
        gold={validate_span(text,x,labels) for x in row['gold']};pred={validate_span(text,x,labels) for x in spans}
        tp+=len(gold&pred);fp+=len(pred-gold);fn+=len(gold-pred)
        for label in labels:
            g={x for x in gold if x[0]==label};p={x for x in pred if x[0]==label};v=per_label[label];v[0]+=len(g&p);v[1]+=len(p-g);v[2]+=len(g-p)
        gchars={i for _,a,b in gold for i in range(a,b)};pchars={i for _,a,b in pred for i in range(a,b)}
        char_tp+=len(gchars&pchars);char_fp+=len(pchars-gchars);char_fn+=len(gchars-pchars)
        if not gold:negative+=1;negative_fp+=bool(pred)
        for _,a,b in gold:values+=1;covered+=set(range(a,b))<=pchars
    return {'examples':len(rows),'exactTypedSpans':scores(tp,fp,fn),'characterCoverageUntyped':scores(char_tp,char_fp,char_fn),'fullyCoveredValues':covered,'goldValues':values,'fullValueRecall':covered/values if values else 0,'negativeExamples':negative,'negativeExamplesWithPrediction':negative_fp,'negativeFalsePositiveRate':negative_fp/negative if negative else 0,'perLabel':{k:scores(*v) for k,v in per_label.items()}}
