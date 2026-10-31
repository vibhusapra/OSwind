import hashlib,importlib.util,json,pathlib,tempfile,unittest
from unittest import mock
path=pathlib.Path('scripts/review-sync-identity-scale.py').resolve();spec=importlib.util.spec_from_file_location('owned_identity_oracle',path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class OracleAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='oswind-identity-oracle-contract-');self.root=pathlib.Path(self.temp.name)/'fixture';self.root.mkdir();(self.root/'library').mkdir();(self.root/'library/memory.sqlite').touch()
        (self.root/'owned-fixture').write_bytes(b'OSwind authored identity bootstrap scale fixture v1')
        self.report=dict(format='OSwind owned identity bootstrap scale component v1',state='completed',rows=1000)
        self.log=pathlib.Path(self.temp.name)/'test.log';self.log.write_text("Test Case '-[OSwindCoreTests.SyncIdentityScaleTests testOwnedIdentityBootstrapAndIncrementalLifetimeScale]' passed (0.1 seconds).\nExecuted 1 test, with 0 failures (0 unexpected)\nIDENTITY_SCALE rows=1000 bootstrapSeconds=1 batches=8 sourceCellsUnchanged=1 lifecycle=4\n")
        self.inputs=pathlib.Path(self.temp.name)/'inputs.json';self.inputs.write_text('{}')
        self.run=dict(state='completed',returncode=0,rows=1000,logPath=str(self.log),logSHA256=module.sha(self.log),sourceInputsPath=str(self.inputs),sourceInputsSHA256=module.sha(self.inputs));self.save()
    def tearDown(self):self.temp.cleanup()
    def save(self):
        (self.root/'report.json').write_text(json.dumps(self.report));(self.root/'run.json').write_text(json.dumps(self.run))
    def refuses(self,root=None):
        with mock.patch.object(module.sqlite3,'connect',side_effect=AssertionError('Refusal must precede database open')) as opened:
            with self.assertRaises((ValueError,FileNotFoundError)):module.review(root or self.root)
            opened.assert_not_called()
    def test_unmarked_or_wrong_marker_refuses_before_database_open(self):
        (self.root/'owned-fixture').unlink();self.refuses();(self.root/'owned-fixture').write_bytes(b'normal library');self.refuses()
    def test_incomplete_or_wrong_size_report_refuses_before_database_open(self):
        self.report['state']='running';self.save();self.refuses();self.report['state']='completed';self.report['rows']=999;self.save();self.refuses()
    def test_failed_or_unrun_driver_refuses(self):
        self.run['returncode']=1;self.save();self.refuses();self.run['returncode']=0;self.run['state']='running';self.save();self.refuses()
    def test_zero_test_log_cannot_substitute_for_executed_fixture(self):
        self.log.write_text('Executed 0 tests, with 0 failures (0 unexpected)\n');self.run['logSHA256']=module.sha(self.log);self.save();self.refuses()
    def test_failed_suite_cannot_promote_one_passed_case(self):
        self.log.write_text(self.log.read_text().replace('0 failures','1 failure'));self.run['logSHA256']=module.sha(self.log);self.save();self.refuses()
    def test_changed_log_or_source_input_refuses(self):
        self.log.write_text(self.log.read_text()+'changed');self.refuses();self.run['logSHA256']=module.sha(self.log)
        source=pathlib.Path(self.temp.name)/'owned-source.txt';source.write_text('before');self.inputs.write_text(json.dumps({str(source):module.sha(source)}));self.run['sourceInputsSHA256']=module.sha(self.inputs);self.save();source.write_text('after');self.refuses()
    def test_live_wal_or_journal_refuses_before_database_open(self):
        for suffix in ['-wal','-journal']:
            side=self.root/'library'/('memory.sqlite'+suffix);side.write_bytes(b'live');self.refuses();side.unlink()
    def test_symlink_database_or_root_refuses(self):
        db=self.root/'library/memory.sqlite';db.unlink();target=pathlib.Path(self.temp.name)/'other.sqlite';target.touch();db.symlink_to(target);self.refuses();alias=pathlib.Path(self.temp.name)/'alias';alias.symlink_to(self.root,target_is_directory=True);self.refuses(alias)
    def test_independent_storage_frames_keep_integer_text_blob_and_unicode_distinct(self):
        self.assertEqual(module.frame(['a']),b'OWSR\x01\x01\x03\x01\x00\x00\x00\x00\x00\x00\x00a')
        self.assertNotEqual(module.frame([1]),module.frame(['1']));self.assertNotEqual(module.frame([b'a']),module.frame(['a']))
        self.assertNotEqual(module.frame(['e\u0301']),module.frame(['é']));self.assertEqual(module.key_name(module.frame(['a\0b'])),'a\0b')
        for value in [float('nan'),float('inf'),True]:
            with self.assertRaises(ValueError):module.frame([value])
        with self.assertRaises(ValueError):module.key_name(module.frame([1]))
        with self.assertRaises(ValueError):module.key_name(module.frame(['a'])+b'trailing')

if __name__=='__main__':unittest.main(verbosity=2)
