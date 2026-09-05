(* How long does a stop-the-world rendezvous take on Windows?

   Measured inside Kind 2 on Windows: minor collections stop every
   domain, and the barrier to gather them takes six to fourteen
   seconds. The phases are `stw_handler`, `interrupt_remote`,
   `minor_leave_barrier` and `empty_minor`; `interrupt_remote` running
   eleven to fourteen seconds is the sharpest part, since that is the
   collecting domain reaching the others rather than waiting for work.

   Four earlier stand-ins failed to provoke anything, but all four
   measured the wrong thing: they timed a sleeping thread and had no
   way to see barrier time at all. This one is measured by
   `probe_pauses.ml`, the same external consumer used on Kind 2, so
   the quantity compared is the same quantity.

   The shape to copy is domains that allocate steadily -- Kind 2 runs
   about twelve, collecting often enough that the barrier is entered
   many times a second.

   Usage: barrier <domains> <seconds> [idle domains] *)

let stop = Atomic.make false

(* Allocate steadily rather than in bursts: a minor collection every
   few milliseconds is what Kind 2's engines produce. *)
let allocating () =
  let keep = ref [] in
  while not (Atomic.get stop) do
    for _ = 1 to 200 do
      keep := (Sys.opaque_identity (ref 0)) :: !keep ;
      if List.length !keep > 400 then keep := []
    done ;
    ignore (Sys.opaque_identity !keep)
  done

(* A domain with nothing to do still has to join every rendezvous. Kind
   2 has several of these: engines waiting on a solver, the supervisor
   between polls. *)
let idling () =
  while not (Atomic.get stop) do
    Thread.delay 0.01
  done

let () =
  let domains = int_of_string Sys.argv.(1) in
  let seconds = float_of_string Sys.argv.(2) in
  let idle = if Array.length Sys.argv > 3 then int_of_string Sys.argv.(3) else 0 in
  Printf.printf "  start allocating=%d idle=%d for %.0fs, pid %d\n%!"
    domains idle seconds (Unix.getpid ()) ;

  let started = Unix.gettimeofday () in
  let spawned =
    List.init domains (fun _ -> Domain.spawn allocating)
    @ List.init idle (fun _ -> Domain.spawn idling)
  in

  (* The same ticker the earlier attempts used, kept only so the two
     kinds of measurement can be compared on one run. The barrier
     times come from the consumer outside. *)
  let worst = ref 0.0 and previous = ref (Unix.gettimeofday ()) in
  while Unix.gettimeofday () -. started < seconds do
    Thread.delay 0.01 ;
    let now = Unix.gettimeofday () in
    let late = now -. !previous -. 0.01 in
    if late > !worst then worst := late ;
    previous := now
  done ;
  Atomic.set stop true ;
  List.iter Domain.join spawned ;
  Printf.printf
    "allocating=%-2d idle=%-2d  cores=%-3d  wall %5.1fs  worst ticker wait %6.2fs\n%!"
    domains idle (Domain.recommended_domain_count ())
    (Unix.gettimeofday () -. started) !worst
