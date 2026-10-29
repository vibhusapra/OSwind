# OSwind Python SDK

Python 3.10+, macOS, standard library only. This is an early local SDK for the
OSwind CLI built from this repository. It is not published to PyPI. From the
repository root, use `PYTHONPATH="$PWD/sdk/python" python3 your_script.py`, or
install this directory into your own Python environment with `pip install ./sdk/python`.
Package installation may fetch setuptools; runtime calls use no Python dependencies.

Read and collect examples, the versioned JSON contract, privacy behavior and
operational limits are in [the collector guide](../../docs/COLLECTORS.md).
No provider API key, account, HTTP service or model download is needed for the
examples. A current OSwind executable and an explicit existing library are required.

Run offline transport checks with `python3 scripts/test-python-sdk.py` from the
repository root. Run actual process checks using `scripts/collector-sdk-smoke.py`.

The current client also exposes `client.privacy_check(memory_id)`. It returns the
last library-owned experimental import-check record and whether it still matches
that source. `privacyAcceptance` remains false: a record does not establish that
PII is absent or that images, audio, video or remote requests are protected. The
server must support `memory_privacy_check`; unsupported requests fail rather than
inventing a check. See [PII scan records](../../docs/PII-SCAN-RECORDS.md).

MIT licensed with the OSwind repository; see [LICENSE](../../LICENSE).
