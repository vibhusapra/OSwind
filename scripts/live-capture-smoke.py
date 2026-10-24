#!/usr/bin/env python3
"""Real ScreenCaptureKit/OCR/privacy smoke. Requires an unlocked Mac and capture access.
Only explicitly targeted synthetic windows are captured. The temporary store is removed.
"""
import json,pathlib,plistlib,shutil,subprocess,sys,tempfile,time,uuid
project=pathlib.Path(__file__).resolve().parents[1]
binary=(project/(sys.argv[1] if len(sys.argv)>1 else '.build/release/oswindctl')).resolve()
processes=[]
with tempfile.TemporaryDirectory(prefix='oswind-live-fixtures-') as directory:
    root=pathlib.Path(directory); data=root/'store'; prefix=[str(binary),'--data',str(data)]
    capabilities=json.loads(subprocess.check_output(prefix+['doctor'],text=True))
    if capabilities.get('screenLocked') or not capabilities.get('screenRecording'):
        raise SystemExit('Real capture smoke requires an unlocked Mac and existing Screen Recording permission for this process.')
    def cli(*args): return subprocess.check_output(prefix+list(args),text=True,timeout=30)
    def capture(bundle): return cli('capture','--app-bundle',bundle).strip()
    bundle='com.oswind.fixture.smoke.'+uuid.uuid4().hex
    try:
        executable=root/'Fixture'; subprocess.run(['swiftc',str(project/'Tests/Fixtures/CaptureFixture.swift'),'-o',str(executable)],check=True)
        for suffix in ['', '.secret']:
            app=root/('Secret.app' if suffix else 'Normal.app'); macos=app/'Contents/MacOS'; macos.mkdir(parents=True)
            shutil.copy2(executable,macos/'Fixture')
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':bundle+suffix,'CFBundleName':'OSwind Synthetic Fixture','CFBundleExecutable':'Fixture','CFBundlePackageType':'APPL'}))
            subprocess.run(['codesign','--force','--deep','--sign','-',str(app)],check=True,capture_output=True)
            processes.append(subprocess.Popen([str(macos/'Fixture')],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE))
        time.sleep(1)
        normal_status=capture(bundle)
        normal=json.loads(cli('search','--mode','keyword','WINDCAPTURE7429'))
        assert normal,normal_status
        memory=normal[0]['memory']; assert memory['bundleID']==bundle
        image=data/memory['imagePath']; assert image.exists(); assert len(memory['regions'])>=3
        secret_status=capture(bundle+'.secret')
        secret=json.loads(cli('search','--mode','keyword','SECRETFRAME7429')); assert secret,secret_status
        redacted=secret[0]['memory']; assert redacted['bundleID']==bundle+'.secret'
        assert '[REDACTED]' in redacted['text'] and 'synthetic-secret-value' not in redacted['text']
        assert not redacted.get('imagePath')
        assert len(list((data/'images').glob('*.jpg')))==1
        settings=json.loads(cli('config')); settings['privacy']['excludedApps'].append(bundle)
        (data/'settings.json').write_text(json.dumps(settings)); assert 'Excluded application' in capture(bundle)
        settings['privacy']['excludedApps'].remove(bundle); settings['privacy']['excludedTitles'].append('OSwind capture verification')
        (data/'settings.json').write_text(json.dumps(settings)); assert 'Excluded window' in capture(bundle)
        assert json.loads(cli('stats'))['count']==2
        cli('delete',memory['id']); assert not image.exists()
        assert not json.loads(cli('search','--mode','keyword','WINDCAPTURE7429'))
        print(json.dumps({'result':'PASS','normal_capture':normal_status,'secret_capture':secret_status,'ocr_regions':len(memory['regions']),'verified':['target identity','live OCR marker','image saved','secret text redacted','secret image absent','app exclusion','window-title exclusion','delete removes image and FTS entry']},indent=2))
    finally:
        for process in processes:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
