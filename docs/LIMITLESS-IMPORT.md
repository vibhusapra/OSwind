# Import saved Limitless API text

OSwind accepts a local UTF-8 JSON response containing `data.lifelogs` (a list)
or `data.lifelog` (one entry). In Settings → Data → Text interchange, choose
**Import Limitless API JSON…**. The CLI uses the same importer:

```sh
/Applications/OSwind.app/Contents/MacOS/oswindctl --data /path/to/library \
  import-limitless /path/to/saved-response.json --json
```

This is an offline text adapter. No account login, API key, network request or
audio/model download is involved. It does not read another application's live
database. Import only files you intend to add to the selected library.

## What carries over

Each entry becomes one searchable **note**, with its original title, start and
end instants, original time-zone strings in its text, Markdown and recursive
content. Speaker names and identifiers, content types, source-reported times and
millisecond offsets remain in the note. Labels are imported claims, not verified
speaker identities. New content-type strings are preserved; unknown field names
are refused so a future schema cannot silently lose data.

The first import uses `isStarred` as the note's favorite state and adds the
`import:limitless` tag. Stable source IDs are `limitless:` plus SHA256 of the
exact UTF-8 external ID. Canonically equivalent Unicode IDs remain distinct.
Reimporting the same ID updates that note while keeping existing user favorites
and tags. The last explicitly imported file wins; this is not a remote sync or
an automatic conflict resolver. Changed evidence invalidates derived links.

Privacy exclusions and secret redaction apply before publication, including the
rendered source metadata and speaker labels. App/title exclusions can only use
the known import identity and title: the API does not supply the original
recording application or website, so their capture-time rules cannot be
reconstructed. Excluded updates leave previously
admitted history intact. Notes have no fabricated media, source URL, timed
transcript or playback. Search can retrieve speaker text, but recording-local
speaker filters do not apply to these notes.

## Completion and errors

The result reports requested, imported and excluded counts, stable IDs and
`hasMorePages`. A non-null `meta.lifelogs.nextCursor` produces an incomplete-page
notice. Import each saved page separately; a response without a cursor does not
prove an entire account was exported. Supplied page counts must match the list.

The whole supplied page is checked before the writer starts. Invalid final
records, duplicate JSON keys/IDs, unsupported fields, reversed ranges and
timestamps without explicit offsets fail the operation. The database mutation
is one transaction; cancellation before commit rolls it back. Cancellation
after a commit can leave an unconfirmed result, so retrying the identical input
is safe. Existing encrypted-library admission and closed-library refusal apply.

Inputs are bounded to 16 MiB, 1,000 entries, 100,000 JSON values, 10,000 content
nodes and 12 nested content levels. JSON arrays have a 10,000-item bound and
the full JSON has a 32-level depth bound. An encoded JSON string is limited to
1 MiB; rendered text is limited to 2 MiB per note. Local input must be a regular
file; final symlinks and special files are refused. Reads check the opened
descriptor's initial/final size and modification stamp. A UTF-8 file BOM is
accepted separately from BOM characters within text. No filesystem timestamp
is used to guess chronology.

## Remaining migration work

This does **not** support the account Data Exports ZIP, historical Rewind
databases/video, audio migration, Limitless chats, remote pagination/download,
speaker identity linking or a byte-for-byte archive round trip. Native file
panel and VoiceOver acceptance require live UI verification. F057 remains
partial when these API-text contracts pass.

The schema was checked against the [official pinned OpenAPI example](https://github.com/limitless-ai-inc/limitless-api-examples/blob/a0e4f567a0745be73573ae73640edb4b8ff210ff/openapi.yml)
and [API documentation](https://www.limitless.ai/developers/docs/api). The
[account export article](https://help.limitless.ai/en/articles/13004987-how-to-download-your-limitless-transcripts-and-account-info)
describes an export request but does not specify its archive member schema.
No vendor code, user account history or private archive was used.
