#!/usr/bin/env python3
"""Admit only the pinned local public validation parquet and freeze its subset.

No download, model import, prediction, test split, normal history or inference
environment is used. Install the separately pinned PyArrow reader explicitly.
"""
import argparse
import datetime
import hashlib
import importlib.metadata
import json
from pathlib import Path
import subprocess
import pii_domain_quality as d
import pii_quality as q

ROOT=Path(__file__).resolve().parent.parent


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--validation-parquet',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.output.exists():raise ValueError('Use a new output directory; existing receipts are preserved')
    with a.validation_parquet.open('rb') as source:data=source.read(d.PARQUET_BYTES+1)
    if len(data)!=d.PARQUET_BYTES or hashlib.sha256(data).hexdigest()!=d.PARQUET_SHA256:
        raise ValueError('Source validation parquet differs from pinned revision')
    if importlib.metadata.version('pyarrow')!='21.0.0':raise ValueError('Use the explicitly pinned PyArrow21.0.0 reader')
    import pyarrow as pa
    import pyarrow.parquet as pq
    # Parse exactly the bytes whose size/hash passed, never reopen a path that
    # could change between validation and the reader's memory mapping.
    table=pq.read_table(pa.BufferReader(data))
    if table.num_rows!=5000 or set(table.column_names)!= {'uid','domain','document_type','document_description','entities','text'}:
        raise ValueError('Changed pinned validation source schema/count')
    converted=[d.convert_row(r) for r in table.to_pylist()]
    full=d.describe(converted)
    if len(full['domains'])!=47 or set(full['annotationCountsByPublisherType'])!=d.KNOWN_TYPES:
        raise ValueError('Changed source domain/annotation inventory')
    selected=d.select_rows(converted);counts=d.describe(selected)
    # Prompt names remain identical to the independently qualified native model.
    authored=json.loads((ROOT/'benchmarks/prototypes/pii/native-hybrid-v1/validation.json').read_text())
    corpus=dict(format='OSwind pinned public synthetic PII validation v1',offsetUnit='Unicode codepoints; end exclusive',labels=authored['labels'],
        policy='Frozen twelve-prompt policy: email, phone, full street/address, SSN, account/card, date of birth, IPv4/IPv6, password and API key. Thirty other publisher types are explicitly out of policy; this does not establish complete PII/PHI treatment.',
        policySourceTypes=d.POLICY_TYPES,excludedSourceTypes=sorted(d.EXCLUDED_TYPES),
        sourceDataset=d.DATASET,sourceRevision=d.REVISION,sourceFileSHA256=d.PARQUET_SHA256,
        scope='Externally authored public synthetic English validation documents; selected for domain/type coverage before inference. Not natural desktop data or verified training-unseen. Publisher annotations are not independently relabeled. Public test and old authored reserved test predictions remain unopened.',
        rows=selected)
    audit=dict(format='OSwind pinned public PII validation source admission v1',preparedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        preparationSource=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),sourceDataset=d.DATASET,sourceRevision=d.REVISION,
        sourceFileSHA256=d.PARQUET_SHA256,sourceFileBytes=d.PARQUET_BYTES,readerVersion='21.0.0',
        selection=dict(seed=d.SEED,perDomainPositiveMaximum=2,perDomainPolicyNegativeMaximum=1,minimumSourcesPerIncludedPublisherType=6,maximumTotalSources=d.MAXIMUM_SELECTED,order='SHA256(seed + NUL + source UID + NUL + original source SHA256)',modelOutputsConsulted=False),
        sourceSummary=full,selectedSummary=counts,malformedSourceRows=0,testSplitDownloaded=False,predictionsGenerated=False,
        license='Apache-2.0 per pinned publisher card; retain attribution',scope=corpus['scope'],
        codeSHA256={name:q.sha256(ROOT/name) for name in ['scripts/pii_domain_quality.py','scripts/test-pii-domain-quality.py','scripts/prepare-pii-domain-quality.py']})
    a.output.mkdir(mode=0o700,parents=True,exist_ok=False)
    target=a.output/'corpus.json';target.write_text(json.dumps(corpus,ensure_ascii=False,indent=2)+'\n');audit['corpusSHA256']=q.sha256(target)
    (a.output/'source-admission.json').write_text(json.dumps(audit,indent=2)+'\n')
    print(json.dumps(dict(state='prepared-no-predictions',**counts,corpusSHA256=audit['corpusSHA256'])),flush=True)


if __name__=='__main__':main()
