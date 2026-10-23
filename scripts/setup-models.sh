#!/bin/bash
set -euo pipefail
command -v brew >/dev/null || { echo 'Install Homebrew from https://brew.sh first.'; exit 1; }
command -v ollama >/dev/null || brew install ollama
command -v whisper-cli >/dev/null || brew install whisper.cpp
model_dir="${OSWIND_MODEL_DIR:-$HOME/Library/Caches/OSwind/models}"
mkdir -p "$model_dir"
chmod 700 "$model_dir"
if ! curl --fail --silent http://127.0.0.1:11434/api/tags >/dev/null; then
    OLLAMA_NO_CLOUD=1 nohup ollama serve > "$model_dir/ollama.log" 2>&1 &
    for i in {1..30}; do
        if curl --fail --silent http://127.0.0.1:11434/api/tags >/dev/null; then break; fi
        sleep 1
    done
fi
ollama pull "${OSWIND_CHAT_MODEL:-qwen3:4b}"
ollama pull "${OSWIND_EMBEDDING_MODEL:-qwen3-embedding:0.6b}"
python3 - "$model_dir" <<'PY'
import hashlib, json, pathlib, sys, urllib.request
root = pathlib.Path(sys.argv[1])
name = 'ggml-base.en.bin'
request = urllib.request.Request('https://huggingface.co/api/models/ggerganov/whisper.cpp/tree/main', headers={'User-Agent':'OSwind-model-setup/0.1'})
entries = json.load(urllib.request.urlopen(request, timeout=60))
entry = next(e for e in entries if e['path'] == name)
expected = entry['lfs']['oid']
path = root / name
if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
    temporary = path.with_suffix('.download')
    try:
        with urllib.request.urlopen('https://huggingface.co/ggerganov/whisper.cpp/resolve/main/' + name, timeout=120) as src, temporary.open('wb') as dest:
            while chunk := src.read(1024*1024): dest.write(chunk)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != expected: raise RuntimeError('Whisper checksum mismatch')
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
print('Whisper model: ' + str(path))
print('Verified SHA256: ' + expected)
(root / 'manifest.json').write_text(json.dumps({'file':name,'sha256':expected,'source':'https://huggingface.co/ggerganov/whisper.cpp','license':'MIT'},indent=2))
PY
printf 'Chat model: %s\n' "${OSWIND_CHAT_MODEL:-qwen3:4b}"
printf 'Whisper executable: %s\n' "$(command -v whisper-cli)"
printf '%s\n' 'Select Ollama and the Whisper model path in OSwind Settings.'
