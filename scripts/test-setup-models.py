#!/usr/bin/env python3
"""Offline setup-script model/host controls; no installers, network or inference."""
from pathlib import Path
import os,subprocess,tempfile,time,unittest

SCRIPT=Path(os.environ.get('OSWIND_SETUP_TEST_SCRIPT',Path(__file__).resolve().parent/'setup-models.sh')).resolve()
class SetupModelRoutingTests(unittest.TestCase):
    def run_setup(self,chat=None,embedding=None,start=False):
        with tempfile.TemporaryDirectory(prefix='oswind-owned-setup-routing-')as temporary:
            root=Path(temporary);bin=root/'bin';bin.mkdir();calls=root/'calls.tsv';count=root/'curl-count'
            def executable(name,body):
                p=bin/name;p.write_text('#!/bin/sh\n'+body+'\n');p.chmod(0o700)
            executable('brew','exit 0');executable('whisper-cli','exit 0')
            executable('python3','/bin/cat >/dev/null\nexit 0')
            executable('ollama','printf "%s\\t%s\\t%s\\t%s\\n" "${OLLAMA_HOST-}" "${OLLAMA_NO_CLOUD-}" "${1-}" "${2-}" >> "$OSWIND_SETUP_TEST_CALLS"')
            executable('curl','if [ "${OSWIND_SETUP_TEST_START-}" = 1 ] && [ ! -e "$OSWIND_SETUP_TEST_CURL_COUNT" ]; then : > "$OSWIND_SETUP_TEST_CURL_COUNT"; exit 1; fi\nexit 0')
            env={k:v for k,v in os.environ.items()if k not in ['OSWIND_CHAT_MODEL','OSWIND_EMBEDDING_MODEL']}
            env.update(PATH=str(bin)+':/usr/bin:/bin',OLLAMA_HOST='https://example.invalid:443',OLLAMA_NO_CLOUD='0',OSWIND_MODEL_DIR=str(root/'models'),OSWIND_SETUP_TEST_CALLS=str(calls),OSWIND_SETUP_TEST_CURL_COUNT=str(count),OSWIND_SETUP_TEST_START='1'if start else'0')
            if chat is not None:env['OSWIND_CHAT_MODEL']=chat
            if embedding is not None:env['OSWIND_EMBEDDING_MODEL']=embedding
            result=subprocess.run(['/bin/bash',str(SCRIPT)],env=env,capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            deadline=time.monotonic()+2
            while start and (not calls.exists()or '\tserve\t'not in calls.read_text())and time.monotonic()<deadline:time.sleep(.01)
            rows=[line.split('\t')for line in calls.read_text().splitlines()]
            self.assertTrue(rows)
            self.assertTrue(all(len(row)==4 and row[:2]==['127.0.0.1:11434','1']for row in rows),rows)
            self.assertEqual([row[3]for row in rows if row[2]=='pull'],[chat or'qwen3.5:4b',embedding or'qwen3-embedding:0.6b'])
            self.assertEqual(sum(row[2]=='serve'for row in rows),int(start))
            self.assertIn('Chat model: '+(chat or'qwen3.5:4b'),result.stdout)
            self.assertEqual((root/'models').stat().st_mode&0o777,0o700)
            self.assertFalse((root/'models/manifest.json').exists(),'Stubbed Whisper phase must not download anything')
    def testFreshPresetPullsCompactChatAndEmbeddingOnlyOnLoopback(self):self.run_setup()
    def testExplicitModelOverridesArePreservedOnLoopback(self):self.run_setup(chat='gemma4:e4b',embedding='owned-embedding:small')
    def testOwnedServerStartAlsoOverridesAmbientRemoteHost(self):self.run_setup(start=True)

if __name__=='__main__':unittest.main(verbosity=2)
