# One-host qualification and baseline

Use one quiet Linux host with the [native build prerequisites](build-run-test.md#build), Python 3.11 or later, Docker with a local daemon, `jq`, `curl`, `taskset` and the existing conformance runner's Tcl dependencies. Install native Tcl or have the `eski-conformance-tcl:8.6` image ready. Start from a clean checkout at the exact revision to qualify. Keep all run output outside the checkout and transfer the matching Search capture program and observed JSON privately. The capture is executable test input and must come from a trusted source. [Combined functional check](build-run-test.md#combined-functional-check)

Create two separate Python environments using the pinned requirements in `test/compatibility/search_clients/requirements-modern.txt` and `requirements-llama.txt`. Preflight compares installed versions with those lists. Prepare the images it reports before running. The Redis 7.4.11 smoke image is separate from the Redis 7.4.12 stock benchmark image. Stock Redis, Valkey, Dragonfly and memtier use the pinned images in the [testbed design](../bench/testbed/design.json). Search and vector fixtures use the pinned Redis Search image. The conformance harness downloads and verifies its versioned Tcl test archives on a first run if they are absent from the cache.

Set the CPU lists to valid, separate cores on this machine. Use physical cores that do not share simultaneous multithreading siblings across the two roles. Reserve 40 consecutive unused loopback ports from the selected base. Preflight reports CPU topology and permitted CPU IDs, checks the selected ports, fingerprints tracked files and inputs, and inspects the images, tools and disk space. It emits JSON and returns a nonzero status on failure. It does not build, start containers or run workloads.

```sh
options=(
  --revision "$(git rev-parse HEAD)"
  --out /path/to/results
  --server-cpus 2 --client-cpus 4,6
  --port-base 17840
  --modern-python /path/to/modern/bin/python
  --llama-python /path/to/llama/bin/python
  --capture /private/path/to/capture.py
  --observed /private/path/to/observed.json
)
python3 -IB tools/rented_run.py preflight "${options[@]}"
python3 -IB tools/rented_run.py run "${options[@]}"
```

An explicit `run` repeats preflight, builds three binaries into a new private result directory, and runs the full functional profile, deterministic simulation, native AOF crash/restart, a native change-log capture and the Search/JSON corpus check. Once the builds pass, each correctness stage runs even when an earlier stage fails. Every correctness stage must pass before any timed work starts. Defaults are 256 virtual seeds with 128 model steps each and 64 native restart cycles with 100 transactions each. Use `--help` for workload sizes, disk-space threshold and typed inputs. Preflight reports the resulting case counts. [Simulation scopes and traces](simulation.md)

The initial baseline runs sequentially after correctness.

| Measurement | Scope |
| --- | --- |
| Stock commands | Existing `bench/run.sh` measures mixed pipeline 1 and 16, GET pipeline 1 and SET pipeline 1 for native Eski, Redis, Valkey and Dragonfly, using separate server and client CPU lists. |
| AOF and the mirror | The append harness measures plaintext AOF off/on and separately compares the local change log off/on with `appendfsync always`. The mirror comparison checks a real cursor and payload, uses the same warmup and workload, and alternates order over two rounds. |
| Vector persistence | The existing vector graph driver measures graph build, restore and startup. It also checks cardinality, search results and the post-restart digest. |
| Search and JSON | Eski and the pinned Redis Search reference receive the same seeded JSON corpus, term queries sorted by numeric rank, and JSON path reads. Every planned request shape is checked before timing. Each engine warms up on the same requests. Two rounds alternate engine order. Raw per-request latency, error counts, throughput and memory are retained. |
| Virtual runtime | A fixed subset of completed seed IDs runs on the client CPU set with explicit rate measurement, including worker startup and trace writing. |

This first baseline covers single-node stock commands, selected persistence costs, text search over JSON and JSON path reads. The specialized workload does not cover vector or hybrid search, aggregate cursors, encrypted or scoped AOF, connection scaling, fill, multi-client search or saturation. The native build runs directly on the host, and container memory limits apply to the reference and load-generator containers. The stock summary retains per-target arguments and limits. Keep the machine idle while the run proceeds.

Each `run-*` directory contains `summary.json`, including the revision, tracked-file hash, binary hashes, CPU topology, OS and kernel, tool and image versions, commands, exit statuses and output paths. Keep the whole directory, including captured input hashes, stage logs, raw benchmark outputs, native data and simulation traces. Store it privately because the run keeps a copy of the capture input. Compare optimization runs from the same machine using the same CPU roles, workload options and image identities.

If correctness completed and a later stage failed or the baseline was interrupted, append `--reuse-correctness /path/to/run-*` to a new `run` using identical options. The coordinator checks the same boot, checkout, tool and input identities, image IDs, binary hashes and recorded correctness summaries and logs before it copies the binaries and reruns the baseline. A changed source or input requires fresh correctness. Keep the original directory to retain the complete correctness artifacts. If a correctness stage failed, rerun normally to collect a fresh receipt.
