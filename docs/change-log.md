# Local change log

Eski can mirror the canonical effects written to its append-only file (AOF) into a segmented local stream. Set these startup options for an unlabelled instance with AOF enabled.

```text
appendonly yes
change-log-dir /path/to/private/change-log
change-log-segment-bytes 67108864
change-log-retain-bytes 1073741824
```

Create a dedicated directory owned by the server's effective user with mode `0700`. Files use mode `0600`, and the `eski-change-` namespace belongs to the stream. Only one Eski writer may use the directory at a time. An empty `change-log-dir` disables the mirror. Encryption, access labels and owners are incompatible with this plaintext format. Eski rejects those combinations at startup and refuses runtime activation of labels or owners with a mirror configured. Decommission any existing plaintext export before adopting encrypted storage or assigning private scopes to its data.

A record contains a complete successful AOF write batch. The payload preserves AOF byte order and may contain multiple changes, expiration or eviction effects, replay metadata and `MULTI`/`EXEC` groups. Each record includes the selected database at the start of the batch. When it is `-1`, Eski had no previous selection for the AOF file and the payload supplies a `SELECT` before database-specific effects. The payload keeps AOF-only syntax, including metadata where applicable. It is intended for local consumers that understand the Eski AOF format. The stream starts with new effects after startup, so a consumer needs its own matching initial state. Eski does not ship a replica or apply this stream to a server.

The mirror writes and syncs records after the AOF write syscall succeeds. AOF sync policy and client replies retain their normal semantics. A mirror record can be durable before its corresponding AOF write is durable. An AOF write can also succeed before the mirror stores it. The files form two separate persistence paths. Readers use shared directory locks so a live read cannot observe a batch while the mirror appends, syncs or prunes it. Use a local filesystem supporting file and directory fsync and advisory flock. The writer syncs new segment contents before publishing their names and syncs the directory after publishing or pruning segments.

Ordinary AOF rewrite keeps the stream's epoch. Eski refuses `DEBUG RELOAD`, `DEBUG LOADAOF`, and changes to `dir` and `appendonly` that would break the mirror while it is configured. A failed AOF write or mirror operation stops capture for the session. Readers can drain the available records and see `Offline` at the tail once the writer releases its lock. This also reports a normal server exit. Each startup validates the existing epoch, truncates an incomplete last frame if present, and publishes a fresh random epoch before retiring the previous one. Complete corrupt records, invalid segment headers and holes between retained segments fail recovery. A restart requires a fresh consumer baseline.

## Read a cursor

Build the local reader from the checkout.

```sh
odin build tools/change_log -out:/tmp/eski-change-log
/tmp/eski-change-log /path/to/private/change-log first
/tmp/eski-change-log /path/to/private/change-log read EPOCH POSITION
```

`first` prints the epoch in hexadecimal and the first retained position in decimal. Positions start at 1 and address the next record to consume. A successful `read` writes one binary AOF batch to stdout and `db=NUMBER next=POSITION` to stderr. Persist the next position with the same epoch after consuming the batch. The reader checks integrity as it scans from the selected segment's start.

`End` (exit 3) means the writer was active and no record exists at the supplied next position yet. `Offline` (4) means the writer is gone. `Wrong_Epoch`, `Stale`, and `Ahead` (5) mean the epoch changed, retention removed the requested history, or the cursor is beyond the stored tail. A separate `Incomplete` or `Corrupt` result (1) reports damaged or incomplete input. Poll again on `End`. When continuity is lost, obtain a new baseline before using a different cursor.

Segments roll at the configured size before appending a record that would cross the target. A single record can exceed the segment target and is capped at 1 GiB. Retention removes whole oldest segments and always keeps the newest segment. A large record can therefore temporarily exceed the retention target.

## File format

The epoch marker contains the eight-byte ASCII magic `ESKICE01`, a 16-byte epoch, and a four-byte CRC32C. A segment starts with `ESKICS01`, the 16-byte epoch, the first eight-byte position, and a four-byte CRC32C. The segment filename also carries the epoch and first position. A frame begins with the bytes `CLF1`, a four-byte payload length, an eight-byte position, a signed four-byte selected database, a four-byte payload CRC32C and a four-byte header CRC32C. Each checksum covers the preceding header bytes or the specified payload. Numeric fields are little-endian.
