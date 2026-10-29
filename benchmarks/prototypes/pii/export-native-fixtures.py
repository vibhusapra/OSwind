#!/usr/bin/env python3
"""Export the three already frozen validation tensors; never reads test results.

Little-endian probe format OSWPII01, u32 case count, then four int64 input
tensors and one float32 reference tensor per case. Each tensor is u32 rank,
rank*u64 dimensions, u64 element count, contiguous data. No source text.
"""
import argparse, hashlib, json, pathlib, struct
import numpy as np

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    inputs = []
    with args.output.open('xb') as output:
        output.write(b'OSWPII01' + struct.pack('<I', 3))
        for index in (0, 4, 8):
            path = args.root / f'compatibility-{index}-v3.npz'
            data = np.load(path, allow_pickle=False)
            inputs.append({'path': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
            for name in ('input_ids', 'attention_mask', 'words_mask', 'text_lengths', 'logits'):
                array = np.ascontiguousarray(data[name], dtype='<f4' if name == 'logits' else '<i8')
                assert 1 <= array.ndim <= 4 and 0 < array.size <= 1_000_000
                output.write(struct.pack('<I', array.ndim))
                output.write(struct.pack('<' + 'Q' * array.ndim, *array.shape))
                output.write(struct.pack('<Q', array.size))
                output.write(array.tobytes())
    print(json.dumps({'inputs': inputs, 'outputSHA256': hashlib.sha256(args.output.read_bytes()).hexdigest()}))

if __name__ == '__main__':
    main()
