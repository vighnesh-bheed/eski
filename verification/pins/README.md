# Vector set pin protocol verification

This bounded model checks the protocol that lets a vector similarity search, or the search half of a compare-and-swap insertion, read a vector set on a compute worker while the coordinator keeps serving other clients. It explores every reachable state of small scenarios and rejects deliberately broken variants of the protocol. It does not prove the executable.

Run from the repository root:

```sh
python3 -I verification/pins/verify.py --output /absolute/path/for/the/receipt
```

`--output` must be absolute and outside the verification sources. `--server` and `--tsan-server` are accepted for the same command form as the other areas and are not used: this area has no implementation probe of its own. The unit tests in `src/vset_threads_test.odin`, `src/compute/wait_test.odin` and `src/vsettype/threads_test.odin` and the driver `test/threading/vsim.py` exercise the code.

## What is modelled

| Source | Abstract step |
| --- | --- |
| `src/vset_threads.odin` `vset_vsim_submit`, `vset_cas_submit`, `vset_pin` | the coordinator pins the set and queues the job; a missing set is answered inline and pins nothing; when the pool cannot take the job (full queue, the memory budget, a stopped pool) the coordinator searches at once and keeps the job, pinned, for the next completion pass |
| `src/compute/pool.odin` `worker_main` | a worker takes the queue head; a cancelled job is completed without running its procedure; a search's completed state ends the reading but not the pin, which holds until the reply has been written from the set |
| `src/vset_threads.odin` `vset_write_hook`, `vset_quiesce`, `vset_settle`, `vset_quiesce_all` | a writer, a free, a lazy-free hand-off or a flush first settles every job that pins the set: a queued job is withdrawn and, unless cancelled, searched and its reply written at that point; a running job is waited for on the pool's condition; a finished job whose reply is not yet written has it written, unless cancelled; the coordinator runs nothing else meanwhile |
| `src/compute_integration.odin` `compute_tick`, `compute_handle`, `compute_ready_run`, `compute_release` | a completed, withdrawn or coordinator-searched job is published unless it was cancelled, its reply written from the set if a writer has not already done so, then released |
| `src/compute_integration.odin` `compute_conn_closed`, `src/owner_commands.odin` `owners_close` | closing a client, or forgetting the owner whose connection holds the job, cancels it |
| `src/compute_integration.odin` `compute_before_fork` | a fork stops and joins the pool, which drains the queue, before the snapshot |

## Bounds and properties

One or two workers, one to three jobs over two sets owned by two owners, five writer programs (a change, a free, a change and a free of different sets, a flush of every set, two changes) and six event programs (none, a client close, a forget, a fork, close and forget, close and fork): 180 scenarios. Each state is checked for: no change or free of a set while a job that pinned it reads; a job reads the set as it was when it was admitted (so a threaded reply equals the inline reply at the same point of the command order); no job reads a freed set; a withdrawn job never runs; cancelled or forgotten work publishes nothing; a fork snapshot has no reading job; every pin is released when the work is done; every reply is written from the set as it was when its job was admitted, whether at publication or by a writer's settle. Every reachable state has a completion path and the progress graph is acyclic, so the protocol terminates under fair worker steps.

## Mutants that must be found

| Mutant | Found as |
| --- | --- |
| `writer_skips_quiesce`: a writer changes the set without settling its pins | a change while a pinning job reads |
| `pin_released_by_procedure`: the pin is released by the job's procedure, which a cancelled job never runs | a writer that can never proceed |
| `pin_not_counted`: submission does not record the pin | a change while a pinning job reads |
| `publish_cancelled`: a cancelled job is published | cancelled work publishes |
| `fork_without_join`: the snapshot is taken without joining the pool | a fork snapshot with a reading job |
| `pin_released_at_completion`: the worker's completion ends the pin, as before replies were written on the coordinator | a reply written from a set that changed after the search |
| `coordinated_without_pin`: a search the coordinator ran because the pool was full keeps no pin | a reply written from a set that changed after the search |

Each counterexample is replayed step by step against the model before it counts.

## What the model does not express

It has no connections and no reply order, so it cannot state that a client's observations are the same whether a job ran on a worker or on the coordinator because the pool was full; the driver's `Twins` cases check that. It does not model memory: that every byte a job holds is reserved is checked by unit tests and the driver. It does not model durations, so the rule that the time a writer spends settling other jobs is not billed to it is checked by the driver. It does not model the commit of `VADD ... CAS` as a write that must itself settle other pins, the table of commits held by a client pause, or connection identity by descriptor, id and token.
