# Request parser checks

Run from the repository root:

```sh
python3 test/request_parser/run.py --odin /path/to/odin
```

The runner builds debug and optimized executables with vet and strict style. Each case runs with both cold and reused scratch storage against read-only input placed at both ends of an accessible mapping, bordered by inaccessible pages. An input write or an out-of-bounds read terminates the check.

The deterministic corpus covers binary arguments, truncation, pipelining, header bytes, permissive framing, authentication limits, oversized headers and inline lines, and native integer overflow. The inline fixtures contain 809 recorded wire observations from Redis 7.4.11, image ID `sha256:4fa24486b8bcca8eec45ee0eb166edc674795e53a2b53d1a9ef263eecebaac85`. They describe the first parsed command; command arity errors remain distinct from parser errors.

Use `--output /tmp/parser-report.json` to retain the seed, fixture hashes and results. These finite checks complement the package unit tests, live protocol comparisons and server regression suite. The harness requires Linux.
