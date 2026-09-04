(* Is 5.5.1 enough for a program shaped like Kind 2?

   The single-domain reproducer (`starve.ml`) hangs on 5.5.0 and is
   clean from 5.5.1. Kind 2 is not clean on 5.5.1: on Windows it still
   runs past its own timeout, silent from the analysis header on. It is
   not shaped like that reproducer either -- it runs about ten domains
   with threads of their own, and one thread in one of them polls the
   wall clock.

   So this asks the same question in that shape. A measuring thread
   that means to wake every 10ms, and around it:

     - `others` extra domains, each running `per` busy threads
     - optionally a busy thread beside the measurer, in its own domain

   The arm with no domain beside it and one thread beside the measurer
   is `starve.ml` again, and is the control that must stay clean on
   5.5.1.

   Usage: many_domains <others> <per> <beside> <seconds>
     others   extra busy domains
     per      busy threads in each of them
     beside   1 to put a busy thread in the measurer's own domain
   *)

let stop = Atomic.make false

let work () =
  let x = ref 0 in
  while not (Atomic.get stop) do
    for i = 1 to 1_000_000 do x := (!x + i) land 0xffff done ;
    ignore (Sys.opaque_identity !x)
  done

let busy_domain per () =
  let mine = List.init (per - 1) (fun _ -> Thread.create work ()) in
  work () ;
  List.iter Thread.join mine

let () =
  let others = int_of_string Sys.argv.(1) in
  let per = int_of_string Sys.argv.(2) in
  let beside = int_of_string Sys.argv.(3) in
  let seconds = float_of_string Sys.argv.(4) in
  Printf.printf "  start others=%d per=%d beside=%d\n%!" others per beside ;

  let started = Unix.gettimeofday () in
  let spawned = List.init others (fun _ -> Domain.spawn (busy_domain per)) in
  let neighbours = List.init beside (fun _ -> Thread.create work ()) in

  let worst = ref 0.0 and stalled = ref 0.0 and count = ref 0 in
  let previous = ref (Unix.gettimeofday ()) in
  while Unix.gettimeofday () -. started < seconds do
    Thread.delay 0.01 ;
    let now = Unix.gettimeofday () in
    let late = now -. !previous -. 0.01 in
    if late > 0.5 then ( incr count ; stalled := !stalled +. late ) ;
    if late > !worst then worst := late ;
    previous := now
  done ;
  Atomic.set stop true ;
  List.iter Thread.join neighbours ;
  List.iter Domain.join spawned ;
  Printf.printf
    "others=%-3d per=%-2d beside=%d  cores=%-3d wall=%5.1fs  worst wait %6.2fs  \
     waits over 0.5s: %-4d  waiting %5.1fs (%.0f%%)\n%!"
    others per beside (Domain.recommended_domain_count ())
    (Unix.gettimeofday () -. started) !worst !count !stalled
    (100. *. !stalled /. (Unix.gettimeofday () -. started))
