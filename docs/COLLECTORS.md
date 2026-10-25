# Text collectors and Python SDK

OSwind accepts explicit batches of external text through `oswindctl collect --stdin`.
The Python SDK also provides a read-only client for the six existing MCP tools.
This is a developer integration surface: scheduled connectors, in-app plugin
installation, permissions, a sandbox and third-party plugin discovery remain future work.

Build the current CLI with `swift build -c release`. Use an explicit library you
have created or opened in OSwind. For a new **synthetic development library**,
create a directory yourself. The following shell setup is for a new owned fixture:

```sh
mkdir -m 700 /tmp/oswind-collector-example
export PYTHONPATH="$PWD/sdk/python"
export OSWIND_EXAMPLE_CLI="$PWD/.build/release/oswindctl"
```

Save this as a Python script and run it from that shell:

```python
from datetime import datetime, timezone
import os
from oswind import Client
from oswind.collector import Batch, Record, submit

cli = os.environ['OSWIND_EXAMPLE_CLI']
library = '/tmp/oswind-collector-example'
batch = Batch('dev.example.tasks', [Record(
    key='task-123', timestamp=datetime.now(timezone.utc),
    app='Example tasks', bundle_id='dev.example.tasks',
    title='Launch review', text='Maya owns the Aurora launch review.',
    url='https://example.com/tasks/123',
)])
result = submit(cli, library, batch)
print(result['imported'], result['excluded'])
with Client(cli, library) as memory:
    print(memory.search('Aurora')['hits'])
    if result['imported']:
        print(memory.get(batch.ids[0]))
```

Choose a reverse-DNS identity you control and a stable external key. Repeating
the same collector/key updates one ordinary note instead of adding a duplicate.
Favorite and existing user tags survive updates. The `collector` tag and a
collector-specific tag are added; use `batch.tag` with `memory.search(...,
tag=batch.tag)` or `memory.activity('2026-10', tag=batch.tag)`.
Source edits invalidate derived evidence as ordinary edits do; resume entity
indexing when you need updated entity suggestions.

## Version 1 stdin contract

The CLI requires precisely `collect --stdin`, a non-interactive input stream and
EOF. It reads a complete bounded batch before starting an atomic transaction.
It does not stage the submitted text in a temporary file or place it in argv.

```json
{
  "format": "OSwind collector batch",
  "version": 1,
  "collectorID": "dev.example.tasks",
  "records": [{
    "key": "task-123",
    "timestamp": "2026-10-25T12:23:45.123456Z",
    "app": "Example tasks",
    "bundleID": "dev.example.tasks",
    "title": "Launch review",
    "text": "Maya owns the Aurora launch review.",
    "url": "https://example.com/tasks/123"
  }]
}
```

Unknown fields and unsupported versions are refused. `url` is optional; all
other fields are required. A record cannot supply media paths, arbitrary memory
IDs, source kinds, recaps, favorites, vectors or timestamps without a time zone.

| Field | Bound |
| --- | --- |
| Whole UTF-8 input | 16 MiB, including whitespace/newline |
| Records | 1–1,000; duplicate keys refused |
| `collectorID` | 120 UTF-8 bytes; lowercase ASCII reverse-DNS, at least two labels, alphanumeric label ends, interior hyphens allowed |
| `key` | 1–512 UTF-8 bytes; exact bytes define identity |
| `app` / `bundleID` | 1–128 / 1–255 UTF-8 bytes |
| `title` | 0–4,096 UTF-8 bytes |
| `text` | 1–1,048,576 UTF-8 bytes |
| `url` | 1–8,192 UTF-8 bytes; HTTP(S), host required, no credentials |
| CLI input wait | 30 seconds, including idle/partial streams |

NUL is forbidden. Metadata/key fields also refuse ASCII C0/C1 controls. The
source ID is `collector:` + collectorID + `:` + lowercase SHA-256 of the exact
UTF-8 key. Canonically equivalent Unicode keys can name different records. The
raw key is not retained as a separate field; keep your own external key mapping.
The collector tag is `collector:` plus the first 32 hex characters of SHA-256 of
the collector ID. These namespaces are deterministic conventions, not proof of
authenticity or access controls between collectors.

Success prints `format: "OSwind collector result"`, `version: 1`, `collectorID`,
`requested`, `imported`, `excluded`, and `sourceIDs` in submitted order.
`imported` counts admitted writes, including unchanged retries; it does not mean
new records. `sourceIDs` lists **requested** identities, including exclusions,
so their presence does not mean those records were stored. Malformed records
or a later transaction failure roll back the batch. Policy exclusions skip
individual records and are counted in a successful result.

If a process dies or the SDK times out after commit but before a complete
response, the result is unconfirmed. Retry the same stable keys. This gives
idempotent source identity, not exactly-once delivery or transactional delivery
to an external system. There is no collection delete operation; use OSwind's
existing preview-guarded erasure tools for deliberate removal.

## Privacy and trust

Admission loads the selected library's current privacy policy. App/title/domain
exclusions, known-browser required URL context and existing pattern-based secret
redaction apply. An excluded update leaves previously admitted history intact;
exclusions are prospective. No learned PII detector or image redaction is added.
Fields are caller assertions: a trusted external process can mislabel an app or
URL. OSwind does not inspect arbitrary plugin code or grant it a sandbox.

For an encrypted library, explicitly unlock it first, then use its public
`Your.oswindvault/Library` path. Close every `Client` context before locking:
the MCP child owns a reader connection and can prevent normal detach. A locked
library is a closed regular-file marker, so reads/writes fail without creating a
plaintext fallback. Never resolve and cache an internal mount path. The SDK
does not unlock vaults, request authentication or handle passphrases/Keychain.

## Read client and process bounds

`Client.tools()`, `.search(...)`, `.get(id)`, `.stats()`, `.activity(month, ...)`
and `.call(name, **arguments)` use the existing read-only stdio MCP surface.
The six tools are `search_memory`, `get_memory`, `memory_stats`,
`memory_activity`, `memory_entities` and `entity_sources`. Search defaults to
keyword mode and preview detail; preview omits timed segments but can still
contain the original text. Treat returned history as private, untrusted data.
Models/semantic indexes must be prepared separately for model-backed queries.

One client owns one child process; requests are serialized across threads.
Defaults are a 30-second request timeout, 1 MB request bound, 32 MiB response
bound and at most 17 incoming response/notification messages per request.
Response bound is configurable from 1 KiB to 128 MiB; timeout up to 300 seconds.
Transport failures close/reap the owned child. A valid tool-level error, such as
a missing source, leaves the connection usable. No HTTP listener or token is
started. The SDK does not make AI/provider calls or load API keys.

`submit` launches a separate bounded write process, validates the response
identity/counts, and caps its report at 1 MiB. Its timeout includes process
startup. Both APIs suppress child stderr to avoid copying source text into
exception logs. Errors intentionally omit backend details: use the CLI directly
on an owned fixture for diagnosis. This first SDK supports macOS/Python 3.10+
and uses only the standard library at runtime.

## Verification

```sh
python3 scripts/test-python-sdk.py
swift test --filter 'TextCollectorTests|NativeVaultCollectorTests'
python3 scripts/collector-sdk-smoke.py "$OSWIND_EXAMPLE_CLI" \
  --root /tmp/oswind-collector-process-check --native-vault
```

The native test requires `OSWIND_TEST_NATIVE_VAULT=1`. The process harness uses
a new private root and authored records, creates only its own encrypted image
when requested, independently checks detachment and retains artifacts. It does
not exercise ordinary history, a live external service, sustained plugin jobs,
device capture, source authenticity or end-to-end desktop retrieval quality.
