#!/usr/bin/env python3
"""Fault controls for archived evidence; no vendor executable or network is used."""
import os, hashlib, importlib.util, json, pathlib, unittest, zipfile
HERE=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('reviewer',HERE/'review-offline-keyword.py');reviewer=importlib.util.module_from_spec(spec);spec.loader.exec_module(reviewer)
ARCHIVE=pathlib.Path(os.environ.get('OSWIND_OFFLINE_KEYWORD_ARCHIVE',str(HERE.parent/'benchmarks/offline-keyword-cli-raw-v1.zip')))

class ArchiveFaults(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with zipfile.ZipFile(ARCHIVE) as z:cls.files={n:z.read(n) for n in z.namelist()}
    def reject(self,alter):
        files=self.files.copy();report=json.loads(files['report.json']);alter(files,report);files['report.json']=json.dumps(report).encode()
        with self.assertRaises(ValueError):reviewer.review(files.__getitem__)
    def test_missing_observation(self):self.reject(lambda f,r:r['measurements'].pop())
    def test_wrong_source(self):self.reject(lambda f,r:r.update(oswindSource='0'*40))
    def test_changed_harness(self):self.reject(lambda f,r:f.update({'measure-keyword-v3.py':b'changed'}))
    def test_forged_median(self):self.reject(lambda f,r:r['summaries'][0]['products']['oswind']['wallMS'].update(median=999))
    def alter_output(self,files,report,change):
        m=next(m for m in report['measurements'] if m['product']=='oswind' and m['case']=='rare-991')
        name=f"{m['rows']}-{m['case']}-{m['iteration']}-{m['product']}.stdout"
        hits=json.loads(files[name]);change(hits);data=json.dumps(hits).encode();files[name]=data;m['stdoutSHA256']=hashlib.sha256(data).hexdigest();m['stdoutBytes']=len(data)
    def test_changed_original_text_with_matching_hash(self):self.reject(lambda f,r:self.alter_output(f,r,lambda h:h[0]['memory'].update(text='altered original')))
    def test_valid_but_changed_score_with_matching_hash(self):self.reject(lambda f,r:self.alter_output(f,r,lambda h:h[0].update(score=h[0]['score']+1)))

if __name__=='__main__':unittest.main()
