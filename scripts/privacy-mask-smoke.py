#!/usr/bin/env python3
"""Owned CLI pattern-union checks; optional immutable before/after baseline.

Only synthetic JSON/replay metadata, a generated tone and a fake local ASR.
No capture permissions, microphone, real credential or normal history.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import wave


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary",type=Path);parser.add_argument("--root",required=True,type=Path)
    parser.add_argument("--baseline",type=Path);parser.add_argument("--baseline-sha256")
    options=parser.parse_args();binary=options.binary.resolve(strict=True)
    assert (options.baseline is None)==(options.baseline_sha256 is None),"Baseline requires exact SHA256"
    baseline=options.baseline.resolve(strict=True) if options.baseline else None
    if baseline:assert sha(baseline)==options.baseline_sha256
    root=options.root.absolute();root.mkdir(mode=0o700,parents=True,exist_ok=False)
    key="sk-"+"a"*20;secret="OwnedOverlapSecret";overlap=key+"-password="+secret
    private="-----BEGIN PRIVATE KEY-----\nOwnedPrivatePayload\n-----END PRIVATE KEY-----"
    cases=[(name,key+"-"+trigger+"="+secret,"[REDACTED]") for name,trigger in [("password","password"),("passwd","passwd"),("api-underscore","api_key"),("api-space","api key"),("secret","secret"),("access-space","access token")]]
    cases += [("private-header",key+private,"[REDACTED]"),("private-grapheme","Cafe\u0301 🦊 "+private+"\u0301 tail","Cafe\u0301 🦊 [REDACTED] tail"),("disjoint","password=OwnedPassword; 123-45-6789","[REDACTED]; [REDACTED]"),("safe-literal","[REDACTED] = harmless literal marker","[REDACTED] = harmless literal marker")]
    source=root/"input.json"
    rows=[dict(id=name,timestamp="2026-10-29T08:00:00Z",kind="note",app="Owned fixture",bundleID="org.oswind.synthetic",title="Owned pattern "+name,text=text,favorite=False,tags=[],regions=[]) for name,text,_ in cases]
    frames=[dict(time=0,text=overlap,regions=[dict(text=overlap,x=0,y=0,width=.5,height=.5)]),dict(time=1,text="Safe frame",regions=[])]
    rows.append(dict(id="replay",timestamp="2026-10-29T08:00:00Z",kind="screen",app="Owned fixture",bundleID="org.oswind.synthetic",title="Owned replay metadata",text=overlap+"\n\nSafe frame",favorite=False,tags=[],regions=[],visualRecording=dict(duration=2,width=100,height=100,codec="hevc",hardwareRequired=False,frames=frames)))
    source.write_text(json.dumps(rows,ensure_ascii=False)+"\n")
    tone=root/"owned-tone.wav"
    with wave.open(str(tone),"wb") as writer:
        writer.setnchannels(1);writer.setsampwidth(2);writer.setframerate(16000)
        writer.writeframes(b"".join(struct.pack("<h",round(1200*math.sin(2*math.pi*440*i/16000))) for i in range(1600)))
    original_tone=sha(tone)
    engine=root/"owned-asr";engine.write_text("#!/usr/bin/env python3\nimport sys,json,pathlib\np=pathlib.Path(sys.argv[sys.argv.index('-of')+1]);p.with_suffix('.json').write_text(json.dumps({'transcription':[{'offsets':{'from':0,'to':100},'text':"+repr(overlap)+"}]}))\nprint('Owned synthetic ASR')\n");engine.chmod(0o700)
    model=root/"owned-model.bin";model.write_bytes(b"owned fake model")
    report=dict(format="OSwind production original-source pattern mask smoke v1",state="running",sourceSHA256=sha(source),toneSHA256=original_tone,operations=[],systems={},normalHistoryOpened=False,scope="Synthetic owned sources. Replay metadata does not establish physical capture; fake ASR/tone does not measure speech quality. No automatic repair of old sanitized records.")
    def save():(root/"report.json").write_text(json.dumps(report,indent=2)+"\n")
    def run(executable,label,command,env):
        expected=report["systems"][label]["binarySHA256"];assert sha(executable)==expected
        result=subprocess.run([str(executable),*map(str,command)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=180)
        name=label+"-"+str(len(report["operations"]));(root/(name+".stdout")).write_bytes(result.stdout);(root/(name+".stderr")).write_bytes(result.stderr)
        report["operations"].append(dict(system=label,action=str(command[2]),exitCode=result.returncode,stdoutSHA256=hashlib.sha256(result.stdout).hexdigest(),stderrBytes=len(result.stderr)));save()
        assert result.returncode==0,(label,command,result.returncode,result.stderr[-1000:]);assert sha(executable)==expected
        return result.stdout
    save()
    try:
        for label,executable in ([("before",baseline)] if baseline else [])+[("after",binary)]:
            library=root/(label+"-library");export=root/(label+"-export.json");markdown=root/(label+"-markdown")
            env=os.environ.copy();env["OSWIND_DATA_DIR"]=str(root/"unexpected-history-must-stay-absent")
            report["systems"][label]=dict(binarySHA256=sha(executable));save()
            run(executable,label,["--data",library,"import",source],env)
            run(executable,label,["--data",library,"export",export],env)
            values=json.loads(export.read_text());by_id={row["id"]:row for row in values};assert len(by_id)==len(rows)
            checks=[dict(id=name,sourceSHA256=hashlib.sha256(text.encode()).hexdigest(),exactExpectedBytes=by_id[name]["text"].encode()==expected.encode(),outputSHA256=hashlib.sha256(by_id[name]["text"].encode()).hexdigest()) for name,text,expected in cases]
            replay=by_id["replay"];replay_clean=replay["text"]=="[REDACTED]\n\nSafe frame" and replay["visualRecording"]["frames"][0]["text"]=="[REDACTED]" and replay["visualRecording"]["frames"][0]["regions"]==[]
            run(executable,label,["--data",library,"export-markdown",markdown,"--include-media"],env)
            markdown_text="\n".join(path.read_text() for path in (markdown/"sources").glob("*.md"))
            # Explicit fixture settings only; fake ASR sees the generated tone.
            (library/"settings.json").write_text(json.dumps(dict(whisperBinary=str(engine),whisperModel=str(model),automaticMaintenance=False,captureOnLaunch=False,apiEnabled=False,routinesEnabled=False)))
            audio=json.loads(run(executable,label,["--data",library,"import-audio",tone,"--retain-audio"],env))
            audio_clean=audio["text"]=="[REDACTED]" and all(segment["text"]=="[REDACTED]" for segment in audio["transcript"]["segments"])
            assert not audio.get("audioPath") and sha(tone)==original_tone
            assert not list((library/"audio/.staging").iterdir())
            assert not (root/"unexpected-history-must-stay-absent").exists()
            result=report["systems"][label];result.update(textChecks=checks,textMismatches=sum(not x["exactExpectedBytes"] for x in checks),replayProtected=replay_clean,markdownOwnedValueAbsent=secret not in markdown_text and "OwnedPrivatePayload" not in markdown_text,audioProtected=audio_clean,retainedAudioAbsent=True,originalToneUnchanged=True,workspacesEmpty=True);save()
            if label=="after":assert result["textMismatches"]==0 and replay_clean and result["markdownOwnedValueAbsent"] and audio_clean
            else:assert result["textMismatches"]>0 and not replay_clean and not result["markdownOwnedValueAbsent"] and not audio_clean,"Baseline did not reproduce retained regressions"
        report["state"]="completed";save();print(json.dumps(dict(systems=list(report["systems"]),afterChecks=len(cases)+3,baselineFailuresRetained=baseline is not None,allCurrentChecksPassed=True)))
    except BaseException as error:
        report.update(state="failed",errorType=type(error).__name__);save();raise


if __name__=="__main__":main()
