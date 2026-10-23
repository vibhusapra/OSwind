#!/usr/bin/env python3
"""Installer contracts with tiny synthetic files and intercepted HTTP only."""
import contextlib,hashlib,importlib.util,io,json,pathlib,sys,tempfile,unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('setup_native_speech',pathlib.Path(__file__).with_name('setup-native-speech.py')); installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)

class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(prefix='oswind-model-setup-test-');self.root=pathlib.Path(self.temporary.name)
        (self.root/'models').mkdir(); self.destination=self.root/'installed';self.content={'Model.mlmodelc/weights.bin':b'synthetic public model','vocabulary.json':b'{}'}
        self.catalog={'repository':'synthetic/public','revision':'fixture','attribution':'Synthetic fixture','license_url':'https://example.test/license','files':[{'path':name,'bytes':len(body),'sha256':hashlib.sha256(body).hexdigest()} for name,body in self.content.items()]}
        (self.root/'models/parakeet-v3-coreml.json').write_text(json.dumps(self.catalog));(self.root/'models/speaker-community1-coreml.json').write_text(json.dumps(self.catalog));self.requests=0
    def tearDown(self):self.temporary.cleanup()
    def response(self,request,**kwargs):
        self.requests+=1; name=request.full_url.split('/resolve/fixture/')[1].split('?')[0];return io.BytesIO(self.content[name])
    def runInstaller(self,response=None,verify=False,model="parakeet"):
        args=['installer','--model',model,'--destination',str(self.destination)]+(['--verify-only'] if verify else [])
        with patch.object(installer,'ROOT',self.root),patch.object(sys,'argv',args),patch.object(installer.urllib.request,'urlopen',response or self.response),contextlib.redirect_stdout(io.StringIO()):installer.main()
    def testVerifiedPublicationPrivatePermissionsAndOfflineReuse(self):
        self.runInstaller();self.assertEqual(self.requests,2)
        for name,body in self.content.items():self.assertEqual((self.destination/name).read_bytes(),body);self.assertEqual((self.destination/name).stat().st_mode&0o777,0o600)
        self.assertEqual(self.destination.stat().st_mode&0o777,0o700)
        self.runInstaller(verify=True);self.assertEqual(self.requests,2)
    def testSpeakerModelUsesExplicitCatalogAndOfflineVerification(self):
        self.runInstaller(model='speakers');self.assertEqual(self.requests,2)
        self.runInstaller(model='speakers',verify=True);self.assertEqual(self.requests,2)
    def testMissingVerifyOnlyNeverDownloads(self):
        with self.assertRaises(ValueError):self.runInstaller(verify=True)
        self.assertEqual(self.requests,0);self.assertFalse(self.destination.exists())
    def testCorruptExistingInstallIsNeverReplaced(self):
        self.runInstaller();target=self.destination/'vocabulary.json';target.write_bytes(b'changed')
        with self.assertRaises(ValueError):self.runInstaller()
        self.assertEqual(target.read_bytes(),b'changed');self.assertEqual(self.requests,2)
    def testBadHashOversizeAndInterruptionCleanOwnedStage(self):
        for failure in ['hash','oversize','cancel']:
            def response(request,**kwargs):
                if failure=='cancel':raise KeyboardInterrupt()
                body=next(iter(self.content.values()));return io.BytesIO(b'x'*len(body) if failure=='hash' else body+b'overflow')
            with self.assertRaises((ValueError,KeyboardInterrupt)):self.runInstaller(response)
            self.assertFalse(self.destination.exists());self.assertEqual(list(self.root.glob('.oswind-model-download-*')),[])
    def testConcurrentDestinationCannotBeOverwritten(self):
        def response(request,**kwargs):
            if not self.destination.exists():self.destination.mkdir();(self.destination/'owned-by-other').write_text('preserve')
            return self.response(request,**kwargs)
        with self.assertRaises(OSError):self.runInstaller(response)
        self.assertEqual((self.destination/'owned-by-other').read_text(),'preserve');self.assertEqual(list(self.root.glob('.oswind-model-download-*')),[])
    def testExistingModelAndParentLinksAreRefused(self):
        self.runInstaller();target=self.destination/'vocabulary.json';target.unlink();target.symlink_to(self.destination/'ATTRIBUTION.txt')
        with self.assertRaises(ValueError):self.runInstaller(verify=True)
        self.assertEqual(self.requests,2)

if __name__=='__main__':unittest.main()
