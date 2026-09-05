# Stop-the-world barriers take seconds on Windows

On Windows, a stop-the-world rendezvous in OCaml 5 can take **five to
ten seconds** when domains that allocate run alongside a domain that
repeatedly enters and leaves a blocking section. Every domain stops for
the duration. Linux and macOS do the same work with barriers of a few
hundredths of a second.

Measured with `runtime_events`, read by a consumer **outside** the
process — an observer inside it is stopped too.

## What happens

`barrier.ml`: N domains allocating steadily, M domains doing nothing
but `Thread.delay 0.01` in a loop. Longest single `stw_handler` span,
three rounds on each platform, 30s per run, four cores:

| allocating / idle | windows-latest | ubuntu-latest | macos-latest |
| --- | --- | --- | --- |
| 11 / 3 | **5.94s, 7.12s, 5.96s** | 0.03s | 0.14s |
| 11 / 1 | **10.56s, 0.29s, 8.29s** | 0.03s | 0.13s |
| **11 / 0** | **0.12s, 0.13s, 0.13s** | 0.03s | 0.13s |
| 6 / 2 | 0.13s, **5.89s**, 0.18s | 0.01s | 0.18s |

`interrupt_remote` and `minor_leave_barrier` run to the same lengths as
`stw_handler` in the affected rounds.

## The idle domain is necessary

Eleven domains allocating flat out with **no** idle domain beside them
never froze: 0.12s, 0.13s, 0.13s. Add **one** idle domain and the
barrier runs to seconds in most rounds. Six of nine runs with an idle
domain froze; none of three without.

It is not simply a blocked domain. An earlier version of this test
parked domains in a single long `Unix.read` and found nothing. What
provokes it is the churn — leaving and re-entering a blocking section
every ten milliseconds — beside domains that keep forcing minor
collections.

## Reproducing it

```
ocamlopt -I +unix -I +threads unix.cmxa threads.cmxa barrier.ml -o barrier
ocamlopt -I +unix -I +runtime_events unix.cmxa runtime_events.cmxa \
  probe_pauses.ml -o pauses

mkdir ev
OCAML_RUNTIME_EVENTS_START=1 OCAML_RUNTIME_EVENTS_DIR="$PWD/ev" \
  ./barrier 11 30 3 &
./pauses "$PWD/ev" 0 32
```

`probe_pauses.ml` prints every runtime phase span over a second, with
the domain it happened in, and totals at the end. A pid of `0` means
"whatever ring is in that directory" — under Cygwin's bash, `$!` is a
Cygwin pid while the ring is named after the Windows one.

On Windows the events directory must be a native path (`cygpath -w`),
or the target cannot create its ring at all.

## Where it was found

Kind 2, a model checker: about twelve domains, some allocating and some
waiting on solver subprocesses between polls. On Windows it freezes for
six to fourteen seconds at a time, and since its wall-clock timeout is
checked in a polling loop, the timeout arrives that late. Same phases,
same external consumer:

```
PAUSE stw_handler          14.16s in domain 4
PAUSE interrupt_remote     14.21s in domain 0
PAUSE minor_leave_barrier  14.16s in domain 4
```

## Not the same as ocaml/ocaml#15028

[#15028](https://github.com/ocaml/ocaml/issues/15028) — a thread that
never yields starving the other threads of its domain — was reported
from this repository, fixed by
[#15029](https://github.com/ocaml/ocaml/pull/15029), and released in
5.5.1. **This is a different problem and persists on 5.5.1**, which is
the version every measurement above was taken on. `starve.ml` in this
repository still demonstrates the fixed one.

## Caveats

- GitHub-hosted runners only, four cores, mingw via `setup-ocaml`.
- Two rounds showed the program's own wall clock stretching to 102.6s
  and 55.5s for a 30 second run while its ticker reported no gap at
  all: those freezes landed inside `Domain.join`, after the ticker had
  stopped. The freeze can outlast the window measuring it.
