#!/usr/bin/env python3
"""Offline failure-admission contracts for the paired query benchmark."""
import copy,importlib.util,pathlib,tempfile,unittest,json
spec=importlib.util.spec_from_file_location('owned_keyword_benchmark',pathlib.Path(__file__).with_name('benchmark-keyword-scope.py'));module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class BenchmarkContracts(unittest.TestCase):
    def result(self):
        return dict(hits=[dict(memory=dict(id='scale-999',text='Owned source 999'),score=1/60,match='keyword')],warnings=[],duration=.1)
    def test_every_result_field_except_elapsed_time_participates(self):
        original=self.result();other=copy.deepcopy(original);other['duration']=100;module.same_results(original,other)
        for key,value in [('score',.8),('match','semantic'),('passage',dict(start=0,length=1))]:
            other=copy.deepcopy(original);other['hits'][0][key]=value
            with self.assertRaises(ValueError):module.same_results(original,other)
        for key,value in [('warnings',['different']),('modelID','different'),('strategy','different'),('resolution',dict(filter='different'))]:
            other=copy.deepcopy(original);other[key]=value
            with self.assertRaises(ValueError):module.same_results(original,other)
        other=copy.deepcopy(original);other['hits'][0]['memory']['text']='changed'
        with self.assertRaises(ValueError):module.same_results(original,other)
    def test_incomplete_or_wrong_source_membership_cannot_pass(self):
        result=self.result();module.validate_hits(result,1000,'rare-phrase')
        for label in ['required','empty-scope']:
            with self.assertRaises(ValueError):module.validate_hits(result,1000,label)
        result['hits'][0]['memory']['id']='scale-1001'
        with self.assertRaises(ValueError):module.validate_hits(result,1000,'rare-phrase')
    def test_rank_order_and_invalid_scores_are_not_erased(self):
        result=self.result();result['hits'].append(dict(memory=dict(id='scale-998',text='Owned source 998'),score=.01))
        other=copy.deepcopy(result);other['hits'].reverse()
        with self.assertRaises(ValueError):module.same_results(result,other)
        for invalid in [float('nan'),float('inf'),True,'1']:
            result['hits'][0]['score']=invalid
            with self.assertRaises(ValueError):module.signature(result)
    def test_quantiles_use_even_median_and_nearest_rank_p95(self):
        self.assertEqual(module.quantiles([4,1,3,2])['medianMS'],2.5)
        self.assertEqual(module.quantiles(list(range(1,21)))['p95MS'],19)
        for invalid in [[],[-1],[float('nan')],[float('inf')]]:
            with self.assertRaises(ValueError):module.quantiles(invalid)
    def test_unmarked_or_incomplete_archive_refuses_before_cloning(self):
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory)
            with self.assertRaises(FileNotFoundError):module.archive_input(root)
            (root/'owned-fixture').write_text('OSwind authored capture scale fixture v1')
            (root/'report.json').write_text(json.dumps(dict(format='OSwind owned canonical capture scale component v1',state='failed',rows=1000)))
            with self.assertRaises(ValueError):module.archive_input(root)
            self.assertFalse((root/'library').exists())

if __name__=='__main__':unittest.main()
