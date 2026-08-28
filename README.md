# A busy thread starves its domain on Windows, from OCaml 5.5.0

Reported upstream as [ocaml/ocaml#15028](https://github.com/ocaml/ocaml/issues/15028),
fixed by [ocaml/ocaml#15029](https://github.com/ocaml/ocaml/pull/15029) — the backup
thread's handle is closed after creation on Windows, so the invalid handle reaching
`caml_plat_thread_equal` came back as `-1`, which read as true.

Confirmed against that branch: with the fix, `busy` and `alloc` finish in 8.0s with a
worst wait of 0.06s, while the 5.5 branch they are based on still hangs.

On Windows, an OCaml thread that never yields voluntarily keeps the
runtime lock and the other threads of its domain never run. Not slowly
— at all, for as long as it goes on computing.

`Thread.yield` still hands the lock over correctly. What stops working
is the handoff nobody asked for: the tick thread that requests one every
50ms.

Linux and macOS are unaffected. OCaml 5.4.0 and earlier are unaffected
on Windows too, so this is a regression in 5.5.0.

## The program

One domain. Some threads that work, and one that means to wake every
10ms and reports how late it was. No oversubscription, no second domain.
The three arms differ only in how the workers behave:

| arm | the workers | who can move the lock along |
| --- | --- | --- |
| `busy` | compute, allocate nothing | only the tick thread |
| `alloc` | allocate hard | only the tick thread, but safe points are everywhere |
| `yield` | compute, then `Thread.yield` | the worker itself |

`workers=0` is the control: the measuring thread alone, nothing to
contend with.

## What happens

Worst lateness of the measuring thread, `workers=1`, on GitHub-hosted
runners:

| | 5.2.1 | 5.3.0 | 5.4.0 | 5.5.0 |
| --- | --- | --- | --- | --- |
| `windows-latest` | 0.05s | 0.05s | 0.06s | **never finishes** |
| `ubuntu-latest` | 0.04s | 0.04s | 0.04s | 0.04s |
| `macos-latest` | 0.28s | 0.21s | 0.25s | 0.12s |

On Windows with 5.5.0, `busy` and `alloc` are killed at the 20s bound
against an 8s expectation, while in the same job on the same binary:

```
== yield workers=1 (expect ~8s) ==
yield  workers=1  in 1 domain  cores=4  wall= 8.0s  worst wait 0.02s
== busy workers=1 (expect ~8s) ==
   NO RESULT: killed at 20s
```

`workers=0` passes on 5.5.0, so `Thread.delay` is fine on its own and
the hang needs a second thread.

The `alloc` arm matters: allocating 100k times per iteration passes safe
points constantly, so the running thread has every opportunity to notice
a request to hand over, and still does not.

An earlier run left it unbounded: it was killed after **5m43s** without
printing its first result, so this is not slowness.

## Not the environment

`setup-ocaml` builds through Cygwin and the runs above go through
`opam exec`. The workflow also launches the same `.exe` straight from
PowerShell, with neither in the picture, and the result is the same —
`busy` still running at 20s, `yield` exiting cleanly after 8.4s.

## Reproducing it

No opam, no dune, no libraries beyond `threads` and `unix`:

```
ocamlopt -I +unix -I +threads unix.cmxa threads.cmxa starve.ml -o starve
./starve busy 1 8      # Windows 5.5.0: does not finish
./starve yield 1 8     # finishes, worst wait ~0.02s
```

Or push to a fork and read `.github/workflows/starve.yml`, which is the
table above.

## What this does not say

Why. The tick thread's sleep and the runtime lock's wait and wake are
platform code, and [ocaml/ocaml#13416][pr] rewrote them for Windows —
replacing winpthreads with SRW locks and condition variables — merged
2025-12-18, after 5.4.0 branched (2025-10-09) and before 5.5.0
(2026-06-19). That makes it a **suspect**, not a conclusion: 5.5.0
carries plenty besides it, and no commit-level bisect has been done.

An earlier guess of ours — that the wake in `st_thread_yield` pairs with
the yielding thread's own wait — is refuted by this program: that would
break `Thread.yield`, and `Thread.yield` is the arm that works.

[pr]: https://github.com/ocaml/ocaml/pull/13416

## Where it was found

Kind 2, a model checker, overran its own `--timeout` on Windows CI by
minutes. Its timeout is a polling loop in a thread; while another thread
in that domain computed, the loop did not run, so nothing checked the
clock. Full CPU throughout, no garbage collection involved.

## Caveats

- GitHub-hosted `windows-latest` runners only. No physical Windows box,
  and only the mingw toolchain that `setup-ocaml` installs.
- Actions logs expire, which is why the results are written out here
  rather than only linked.
