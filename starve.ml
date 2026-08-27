(* On Windows, from OCaml 5.5.0, a thread that never yields keeps its
   domain to itself and the other threads of that domain never run.

   The threads of one domain take turns: one holds the runtime lock and
   runs, the others wait. A thread gives the lock up when it blocks, or
   sleeps, or calls Thread.yield. A thread that only computes gives it
   up for none of those reasons, so the runtime has a tick thread that
   asks for a handoff every 50ms.

   This program is one domain, some threads that work, and one that
   means to wake every 10ms and reports how late it was. Nothing here
   is oversubscribed and there is no second domain, since the question
   is about threads sharing one lock.

   Three arms, and the difference between them is what makes this a
   report rather than a puzzle:

     busy    the workers compute and allocate nothing, so only the tick
             thread can move the lock along
     alloc   the workers allocate hard, so they pass safe points
             thousands of times a second
     yield   the workers call Thread.yield, handing the lock over
             themselves

   On Windows with 5.5.0, `busy` and `alloc` do not finish -- not
   slowly, at all -- while `yield` finishes in hundredths of a second
   in the same job on the same binary. Under 5.4.0 and earlier all
   three finish, on the same runner. Linux and macOS are unaffected
   throughout.

   So the handoff itself works, and what fails is the handoff nobody
   asked for. Why, this program does not say: the tick thread's sleep
   and the lock's wait and wake are both platform code, and ocaml/ocaml
   PR #13416 rewrote them for Windows between 5.4.0 and 5.5.0, which
   makes it a suspect and not a conclusion.

   Usage: starve <busy|alloc|yield> <workers> <seconds>

   Build with no opam and no dune:
     ocamlopt -I +unix -I +threads unix.cmxa threads.cmxa starve.ml -o starve *)

let stop = Atomic.make false

let busy_work () =
  let x = ref 0 in
  while not (Atomic.get stop) do
    for i = 1 to 1_000_000 do x := (!x + i) land 0xffff done ;
    ignore (Sys.opaque_identity !x)
  done

let yield_work () =
  let x = ref 0 in
  while not (Atomic.get stop) do
    for i = 1 to 1_000_000 do x := (!x + i) land 0xffff done ;
    ignore (Sys.opaque_identity !x) ;
    Thread.yield ()
  done

let alloc_work () =
  let keep = ref (Obj.repr 0) in
  while not (Atomic.get stop) do
    for _ = 1 to 100_000 do
      keep := Obj.repr (Sys.opaque_identity (ref 0))
    done ;
    ignore (Sys.opaque_identity !keep)
  done

let () =
  let mode = Sys.argv.(1) in
  let workers = int_of_string Sys.argv.(2) in
  let seconds = float_of_string Sys.argv.(3) in
  let work = match mode with
    | "busy" -> busy_work
    | "yield" -> yield_work
    | "alloc" -> alloc_work
    | m -> failwith ("unknown mode " ^ m)
  in
  (* Said before anything is spawned, so that a run which prints
     nothing at all is known to have started. *)
  Printf.printf "  start %s workers=%d\n%!" mode workers ;
  let started = Unix.gettimeofday () in

  (* Every thread here, the measuring one included, belongs to the one
     domain the program starts with. A run with no workers is the
     control for Thread.delay itself. *)
  let threads = List.init workers (fun _ -> Thread.create work ()) in

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
  List.iter Thread.join threads ;
  let wall = Unix.gettimeofday () -. started in
  Printf.printf
    "%-6s workers=%-2d in 1 domain  cores=%-3d wall=%5.1fs  \
     worst wait %6.2fs  waits over 0.5s: %-4d  waiting %5.1fs of wall (%.0f%%)\n%!"
    mode workers (Domain.recommended_domain_count ()) wall !worst !count
    !stalled (100. *. !stalled /. wall)
