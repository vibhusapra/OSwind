"""Strict source/annotation admission for a pinned public synthetic PII corpus.

The publisher supplies entity strings without character offsets. Only one exact
occurrence is accepted; no normalization, fuzzy matching or gold guessing.
Selection sees annotations but never model output. No downloads or model imports.
"""
import ast
from collections import Counter
import hashlib
import json
import re

DATASET='gretelai/gretel-pii-masking-en-v1'
REVISION='e06eb1499ca8d54470f085021cd8e54f9efac7fd'
PARQUET_BYTES=2031349
PARQUET_SHA256='3de64be0dddd0dc8a6a1a1368533cc1efe8a9ec290f87feaa064e4e78a5d22b8'
POLICY_TYPES={
    'email':'email','phone_number':'phone','address':'address','street_address':'address',
    'ssn':'government_id','account_number':'financial_id','credit_card_number':'credit_card',
    'date_of_birth':'date_of_birth','ipv4':'ip_address','ipv6':'ip_address',
    'password':'secret','api_key':'secret',
}
EXCLUDED_TYPES=frozenset({
    'first_name','last_name','medical_record_number','date','employee_id','device_identifier',
    'name','biometric_identifier','customer_id','bank_routing_number','license_plate','city',
    'unique_identifier','company_name','date_time','user_name','certificate_license_number',
    'url','country','vehicle_identifier','national_id','health_plan_beneficiary_number',
    'coordinate','tax_id','time','swift_bic','postcode','state','pin','cvv',
})
KNOWN_TYPES=frozenset(POLICY_TYPES)|EXCLUDED_TYPES
SEED='oswind-gretel-validation-v1'
MAXIMUM_SELECTED=192
MINIMUM_TYPE_SOURCES=6


def convert_row(row):
    if not isinstance(row,dict) or set(row)!= {'uid','domain','document_type','document_description','entities','text'}:
        raise ValueError('Changed dataset column schema')
    for key,limit in [('uid',128),('domain',128),('document_type',256),('document_description',8192),('entities',32768),('text',4096)]:
        if not isinstance(row[key],str) or not row[key] or len(row[key])>limit or '\x00' in row[key]:
            raise ValueError('Invalid bounded dataset field: '+key)
        row[key].encode('utf-8')
    if not re.fullmatch('[A-Za-z0-9_-]+',row['uid']) or not re.fullmatch('[a-z0-9-]+',row['domain']):
        raise ValueError('Invalid dataset identity/domain')
    try:entities=ast.literal_eval(row['entities'])
    except (SyntaxError,ValueError,TypeError,RecursionError) as error:
        raise ValueError('Invalid literal annotation collection') from error
    if not isinstance(entities,list) or not 1<=len(entities)<=64:
        raise ValueError('Invalid bounded annotation collection')
    gold=[];annotations=[];seen=set()
    for entity in entities:
        if not isinstance(entity,dict) or set(entity)!= {'entity','types'}:
            raise ValueError('Changed annotation schema')
        value,types=entity['entity'],entity['types']
        if not isinstance(value,str) or not value or len(value)>1024 or not isinstance(types,list) or not 1<=len(types)<=8:
            raise ValueError('Invalid bounded annotation')
        if any(not isinstance(t,str) or t not in KNOWN_TYPES for t in types) or len(set(types))!=len(types):
            raise ValueError('Unknown or duplicate source entity type')
        categories={POLICY_TYPES[t] for t in types if t in POLICY_TYPES}
        if len(categories)>1:raise ValueError('Ambiguous annotation policy category')
        # A second overlapping occurrence is ambiguous too (str.count misses it).
        start=row['text'].find(value)
        if start<0 or row['text'].find(value,start+1)>=0:
            raise ValueError('Missing or ambiguous literal entity occurrence')
        end=start+len(value);identity=(start,end,tuple(sorted(types)))
        if identity in seen:raise ValueError('Duplicate source annotation')
        seen.add(identity)
        annotations.append(dict(start=start,end=end,types=sorted(types),value=value))
        if categories:gold.append(dict(start=start,end=end,label=next(iter(categories)),value=value,sourceTypes=sorted(types)))
    # Overlapping policy annotations would double-count one underlying value.
    ordered=sorted(gold,key=lambda g:(g['start'],g['end']))
    if any(a['end']>b['start'] for a,b in zip(ordered,ordered[1:])):
        raise ValueError('Overlapping policy annotations')
    digest=hashlib.sha256(row['text'].encode()).hexdigest()
    return dict(id='gretel-validation-'+row['uid'],split='validation',text=row['text'],gold=ordered,
        source=DATASET+'@'+REVISION,sourceUID=row['uid'],sourceSHA256=digest,
        domain=row['domain'],documentType=row['document_type'],annotations=annotations)


def rank(row):
    return hashlib.sha256((SEED+'\x00'+row['sourceUID']+'\x00'+row['sourceSHA256']).encode()).hexdigest()


def source_types(row):return {t for g in row['gold'] for t in g['sourceTypes'] if t in POLICY_TYPES}


def select_rows(rows):
    if not isinstance(rows,list) or not 1<=len(rows)<=5000:raise ValueError('Invalid bounded source collection')
    if len({r['id'] for r in rows})!=len(rows) or len({r['sourceSHA256'] for r in rows})!=len(rows):
        raise ValueError('Duplicate source identity or text')
    selected={};domains=sorted({r['domain'] for r in rows})
    for domain in domains:
        for positive,maximum in [(True,2),(False,1)]:
            candidates=sorted((r for r in rows if r['domain']==domain and bool(r['gold'])==positive),key=rank)
            for row in candidates[:maximum]:selected[row['id']]=row
    for kind in sorted(POLICY_TYPES):
        def count():return sum(kind in source_types(r) for r in selected.values())
        for row in sorted((r for r in rows if kind in source_types(r)),key=rank):
            if count()>=MINIMUM_TYPE_SOURCES:break
            selected[row['id']]=row
        if count()<MINIMUM_TYPE_SOURCES:raise ValueError('Insufficient source coverage for '+kind)
    if len(selected)>MAXIMUM_SELECTED:raise ValueError('Selection exceeds predeclared source budget')
    return sorted(selected.values(),key=rank)


def describe(rows):
    return dict(sources=len(rows),positiveSources=sum(bool(r['gold']) for r in rows),
        policyNegativeSources=sum(not r['gold'] for r in rows),goldValues=sum(len(r['gold']) for r in rows),
        domains=dict(sorted(Counter(r['domain'] for r in rows).items())),
        policyValuesByCategory=dict(sorted(Counter(g['label'] for r in rows for g in r['gold']).items())),
        policySourceCountsByPublisherType={t:sum(t in source_types(r) for r in rows) for t in sorted(POLICY_TYPES)},
        annotationCountsByPublisherType=dict(sorted(Counter(t for r in rows for a in r['annotations'] for t in a['types']).items())),
        maxCharacters=max(len(r['text']) for r in rows))
