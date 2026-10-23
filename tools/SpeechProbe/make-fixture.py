#!/usr/bin/env python3
"""Generate a clearly synthetic A/B/A/B fixture with a local Kokoro CLI.

Requires an existing command accepting --input, --output, --voice. The measured
run used the user's installed mlx-audio Kokoro-82M helper. No voice cloning.
"""
import argparse,array,json,math,pathlib,subprocess,wave
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--tts',required=True);parser.add_argument('--output',required=True);args=parser.parse_args()
root=pathlib.Path(args.output).resolve();root.mkdir(parents=True,exist_ok=False)
texts={'a1':"Let's release the desktop memory preview on Friday. I will own the capture tests and the privacy checklist.",'b1':"That works for me. I'll handle local model setup and the search benchmark. We should keep recording off until setup is complete.",'a2':"What did we decide about the archive format? I want the media and transcripts to restore together, including their timestamps.",'b2':"The first package is local and unencrypted. We will verify the restored copy, and add encryption in the next milestone."}
for key,text in texts.items():
    script=root/(key+'.txt');script.write_text(text+'\n')
    subprocess.run([args.tts,'--input',str(script),'--output',str(root/(key+'.wav')),'--voice','af_heart' if key[0]=='a' else 'am_echo'],check=True)
segments=[];timeline=0.0
with wave.open(str(root/'two-speaker.wav'),'wb') as result:
    result.setnchannels(1);result.setsampwidth(2);result.setframerate(24000)
    for number,key in enumerate(texts):
        with wave.open(str(root/(key+'.wav')),'rb') as source:
            assert (source.getnchannels(),source.getsampwidth(),source.getframerate())==(1,2,24000),'Expected mono 24 kHz PCM16'
            frames=source.readframes(source.getnframes());duration=source.getnframes()/24000
        values=array.array('h',frames);assert values and math.sqrt(sum(x*x for x in values)/len(values))>20,'Silent TTS output'
        result.writeframes(frames);segments.append({'start':timeline,'end':timeline+duration,'speaker':key[0].upper(),'stock_voice':'af_heart' if key[0]=='a' else 'am_echo','text':texts[key]});timeline+=duration
        if number<3:result.writeframes(b'\0\0'*18000);timeline+=0.75
(root/'reference.json').write_text(json.dumps({'synthetic':True,'seconds':timeline,'segments':segments,'scope':'known stock voice sources and intervals; not natural-meeting DER or annotated VAD'},indent=2)+'\n')
print('Generated synthetic source fixture:',round(timeline,3),'seconds')
