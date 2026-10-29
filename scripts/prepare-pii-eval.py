#!/usr/bin/env python3
"""Create deterministic authored PII contract fixtures before model inference.

Synthetic identifiers only. Not a representative desktop corpus, verified unseen
training data, compliance test or competitive ranking. Separate validation/test
namespaces; inference uses validation until an operating point is frozen.
"""
import argparse,hashlib,json,pathlib
LABELS={'email address':'email','phone number':'phone','location address':'address','ssn':'government_id','passport number':'government_id','driver license':'government_id','account number':'financial_id','credit card':'credit_card','dob':'date_of_birth','ip address':'ip_address','password':'secret','api key':'secret'}
VALUES={
 'email address':lambda n:f'owned.person{n}@example.test',
 'phone number':lambda n:f'+1 (202) 555-{(100 if n<100 else 150)+n%100:04d}',
 'location address':lambda n:f'{410+n} Willow Lane, Springfield, MA 01103',
 'ssn':lambda n:f'000-12-{1000+n:04d}',
 'passport number':lambda n:f'X{1000000+n}',
 'driver license':lambda n:f'D{1000000+n}',
 'account number':lambda n:f'9042-{1200+n:04d}-7781',
 'credit card':lambda n:'4111 1111 1111 1111',
 'dob':lambda n:f'1988-06-{1+n%28:02d}',
 'ip address':lambda n:f'192.0.2.{1+n%200}',
 'password':lambda n:f'OwnedOnly-{n}-Raven!42',
 'api key':lambda n:'sk-owned-'+hashlib.sha256(str(n).encode()).hexdigest()[:32],
}
CONTEXT={'email address':'personal email','phone number':'private phone number','location address':'home street address','ssn':'Social Security number','passport number':'passport number','driver license':'driver license number','account number':'bank account number','credit card':'credit card number','dob':'date of birth','ip address':'client IP address','password':'password','api key':'API key'}
VALIDATION_TEMPLATES=['Owned support note: my {kind} is {value}. Keep this private.','Contact record | {kind}: {value} | verified by owner.','Please update the {kind} to {value} in this private profile.','🔒 Private {kind} = {value}; do not include it in a public recap.']
TEST_TEMPLATES=['Imported private form\n{kind}\t{value}\nEnd of field.','In a local transcript the speaker dictated their {kind}, {value}, for verification.','Record {nonce}: the value {value} belongs to the confidential {kind} field.','\ufeffPrivate settings panel: {kind} → {value}.','{"record":"{nonce}","field":"{kind}","value":"{value}"}','The following belongs to this person only: {kind} ({value}).','An OCR card displays {value} beneath the label {kind}.','Cafe\u0301 profile 👩🏽‍💻 — {kind}: {value}\nPlease save the correction locally.']
NEGATIVES=[
 'The Atlas retrieval benchmark is owned by Mira Chen at Northwind Research.',
 'Documentation is at https://developer.apple.com/documentation and is public.',
 'Release date: 2026-11-15. This is a software release, not a birth date.',
 'The package version is 1.24.2 and the model has 32 million parameters.',
 'Our meeting starts at 10:30; the budget is 42 dollars for the demo.',
 'Use the placeholder <YOUR_API_KEY> in this public setup tutorial.',
 'The password policy requires a long value. No password is shown here.',
 'Email address validation rejects missing at-signs; this describes a rule.',
 'Phone number formatting and international prefixes need unit tests.',
 'The account is named Atlas Team. No account number is displayed.',
 'Room 42 is upstairs; pick up the USB-C adapter at reception.',
 'The progress report has 954 passes and two physical acceptance skips.',
 'A sample response says [REDACTED]. That is literal placeholder text.',
 'This page explains how Social Security numbers are structured without an identifier.',
 'A passport number is required on the form, but this blank form has no value.',
 'Use driver license as a search label; no license credential is present.',
 'A credit card number must pass a checksum. The input is currently blank.',
 'The person turned 28 last month. A date of birth is not present.',
 'IP address is the name of a networking concept in this public glossary.',
 'The SHA256 digest is abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd.',
 'The API returned status 200 with 1024 results and a 512-dimensional vector.',
 'Swift code: let passwordPolicyEnabled = true; let accountCount = 17.',
 'Identifiers in this document are synthetic and no secret fields are populated.',
 'Open-source model licenses include Apache-2.0 and MIT; review the notices.',
]
def build():
 rows=[]
 for split,templates,copies,offset in [('validation',VALIDATION_TEMPLATES,1,0),('test',TEST_TEMPLATES,2,100)]:
  for category,label in LABELS.items():
   for i,template in enumerate(templates):
    n=offset+i;value=VALUES[category](n);nonce=hashlib.sha256(f'{split}:{category}:{i}'.encode()).hexdigest()[:12]
    # Use replace rather than format: one test template contains literal JSON braces.
    text=template.replace('{kind}',CONTEXT[category]).replace('{value}',value).replace('{nonce}',nonce)
    assert text.count(value)==1 and '[REDACTED]' not in text
    start=text.index(value);end=start+len(value)
    rows.append({'id':split+'-'+nonce,'split':split,'text':text,'gold':[{'start':start,'end':end,'label':label,'value':value}],'source':'authored-synthetic-v1'})
  for repeat in range(copies):
   for i,text in enumerate(NEGATIVES):
    if split=='test':text=f'Owned negative example {repeat}: '+text+' This is a public technical note.'
    nonce=hashlib.sha256(f'{split}:negative:{repeat}:{i}'.encode()).hexdigest()[:12]
    rows.append({'id':split+'-'+nonce,'split':split,'text':text,'gold':[],'source':'authored-synthetic-v1'})
 assert len(rows)==216 and len({x['id'] for x in rows})==216 and len({x['text'] for x in rows})==216
 return rows
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',required=True,type=pathlib.Path);a=p.parse_args();a.output.parent.mkdir(parents=True,exist_ok=True)
 payload={'format':'OSwind authored PII contracts v1','offsetUnit':'Unicode codepoints; end exclusive','labels':LABELS,'policy':'Detect explicitly contextual contact, government, financial, birth-date, network and authentication identifiers. Names, public URLs, ages, generic dates, amounts and placeholders alone are not in this policy. Synthetic values remain positives based on displayed type/context.','scope':'Authored contract examples; template-limited and not natural desktop or training-independent quality acceptance. Test negatives share source concepts with validation and are not independent natural data.','rows':build()}
 data=(json.dumps(payload,ensure_ascii=False,indent=2)+'\n').encode();a.output.write_bytes(data);print(json.dumps({'sha256':hashlib.sha256(data).hexdigest(),'rows':len(payload['rows']),'validation':sum(x['split']=='validation' for x in payload['rows']),'reservedTest':sum(x['split']=='test' for x in payload['rows'])}))
if __name__=='__main__':main()
