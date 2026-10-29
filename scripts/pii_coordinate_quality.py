"""Quality scoring from source-bound codepoint coordinates, without raw text.

This verifies interval metrics and identities, not literal source alignment,
UTF-16 conversion, graphemes, native inference or rendered output. Those require
the separately retained local source/native receipts. No detector is replicated.
"""
import math
import re


def scores(tp,fp,fn):
    precision=tp/(tp+fp) if tp+fp else 0
    recall=tp/(tp+fn) if tp+fn else 0
    return dict(tp=tp,fp=fp,fn=fn,precision=precision,recall=recall,
                f1=2*precision*recall/(precision+recall) if precision+recall else 0)


def evaluate(rows,results,labels):
    if not isinstance(rows,list) or not isinstance(results,list) or not 1<=len(rows)<=10000 or len(rows)!=len(results):
        raise ValueError('Missing/extra coordinate source')
    if not isinstance(labels,(set,frozenset)) or not labels or any(not isinstance(x,str) for x in labels):
        raise ValueError('Invalid coordinate categories')
    if any(not isinstance(r,dict) or not isinstance(r.get('id'),str) or not 1<=len(r['id'])<=200 for r in rows+results):
        raise ValueError('Invalid coordinate identity')
    expected={r['id']:r for r in rows};actual={r['id']:r for r in results}
    if len(expected)!=len(rows) or len(actual)!=len(results) or expected.keys()!=actual.keys():
        raise ValueError('Duplicate or mismatched coordinate source')
    tp=fp=fn=char_tp=char_fp=char_fn=negative=negative_fp=values=covered=0
    per_label={k:[0,0,0] for k in labels}
    for identity,row in expected.items():
        length=row.get('textCharacters');digest=row.get('sourceSHA256');prediction=actual[identity]
        if type(length) is not int or not 1<=length<=4096 or not isinstance(digest,str) or not re.fullmatch('[0-9a-f]{64}',digest):
            raise ValueError('Invalid bounded coordinate source')
        if prediction.get('sourceSHA256')!=digest:raise ValueError('Changed coordinate source')
        def spans(items):
            if not isinstance(items,list) or len(items)>1000:raise ValueError('Invalid bounded coordinate spans')
            output=set()
            for span in items:
                if not isinstance(span,dict):raise ValueError('Invalid coordinate span')
                a,b,label=span.get('start'),span.get('end'),span.get('label')
                if type(a) is not int or type(b) is not int or not 0<=a<b<=length or not isinstance(label,str) or label not in labels:
                    raise ValueError('Invalid coordinate range/category')
                if 'score' in span and (type(span['score']) not in [int,float] or not math.isfinite(span['score']) or not 0<=span['score']<=1):
                    raise ValueError('Invalid coordinate confidence')
                output.add((label,a,b))
            return output
        gold,pred=spans(row.get('gold')),spans(prediction.get('spans'))
        tp+=len(gold&pred);fp+=len(pred-gold);fn+=len(gold-pred)
        for label in labels:
            g={s for s in gold if s[0]==label};p={s for s in pred if s[0]==label};v=per_label[label]
            v[0]+=len(g&p);v[1]+=len(p-g);v[2]+=len(g-p)
        gc={i for _,a,b in gold for i in range(a,b)};pc={i for _,a,b in pred for i in range(a,b)}
        char_tp+=len(gc&pc);char_fp+=len(pc-gc);char_fn+=len(gc-pc)
        if not gold:negative+=1;negative_fp+=bool(pred)
        for _,a,b in gold:values+=1;covered+=set(range(a,b))<=pc
    return dict(examples=len(rows),exactTypedSpans=scores(tp,fp,fn),characterCoverageUntyped=scores(char_tp,char_fp,char_fn),
        fullyCoveredValues=covered,goldValues=values,fullValueRecall=covered/values if values else 0,
        negativeExamples=negative,negativeExamplesWithPrediction=negative_fp,
        negativeFalsePositiveRate=negative_fp/negative if negative else 0,perLabel={k:scores(*v) for k,v in per_label.items()})
