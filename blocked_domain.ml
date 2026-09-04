(* Does a domain blocked in a read hold up everyone else's collections?

   In Kind 2 on Windows the whole process goes quiet for about 5.7
   seconds at a time -- every domain, including one with nothing to do
   but tick -- while collecting almost nothing. The duration is the
   same whether it happens fifty times or once, which is the shape of
   something waiting for a fixed event rather than doing work.

   Kind 2's engine domains spend their time blocked reading answers
   from solver subprocesses, and about 5s is an ordinary query. A minor
   collection in OCaml 5 stops every domain and needs every domain to
   join it. So: if a domain sitting in a blocking read does not get
   serviced, every collection that starts while a solver is thinking
   would freeze the process until that read returns.

   This asks that directly. Some domains allocate, so collections keep
   happening. One domain sits in a read that only completes every
   `block` seconds. A ticker measures how long nothing runs.

   An earlier arm of ours looked like this and found nothing, because
   its reads completed every 0.5s -- shorter than the threshold it
   reported at. The block length is the whole point, so it is a
   parameter here.

   Usage: blocked_domain <busy domains> <blocked domains> <block secs> <secs> *)

let stop = Atomic.make false

let allocate () =
  let keep = ref (Obj.repr 0) in
  while not (Atomic.get stop) do
    for _ = 1 to 100_000 do
      keep := Obj.repr (Sys.opaque_identity (ref 0))
    done ;
    ignore (Sys.opaque_identity !keep)
  done

(* Blocked in a read for `block` seconds at a time, as an engine
   waiting on a solver is. *)
let blocked fd () =
  let buf = Bytes.create 1 in
  while not (Atomic.get stop) do
    match Unix.read fd buf 0 1 with _ -> () | exception _ -> ()
  done

let () =
  let busy = int_of_string Sys.argv.(1) in
  let blocked_count = int_of_string Sys.argv.(2) in
  let block = float_of_string Sys.argv.(3) in
  let seconds = float_of_string Sys.argv.(4) in
  Printf.printf "  start busy=%d blocked=%d block=%.1fs\n%!"
    busy blocked_count block ;

  let started = Unix.gettimeofday () in
  let pipes = List.init blocked_count (fun _ -> Unix.pipe ()) in
  let spawned =
    List.map (fun (r, _) -> Domain.spawn (blocked r)) pipes
    @ List.init busy (fun _ -> Domain.spawn allocate)
  in

  (* One byte per `block` seconds, so each blocked domain is inside a
     read for that long. *)
  let feeder =
    Thread.create
      (fun () ->
        while not (Atomic.get stop) do
          Thread.delay block ;
          List.iter
            (fun (_, w) ->
              try ignore (Unix.write w (Bytes.make 1 'x') 0 1) with _ -> ())
            pipes
        done)
      ()
  in

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
  Thread.join feeder ;
  List.iter
    (fun (_, w) -> try ignore (Unix.write w (Bytes.make 1 'x') 0 1) with _ -> ())
    pipes ;
  List.iter Domain.join spawned ;
  List.iter (fun (r, w) ->
    (try Unix.close r with _ -> ()) ; try Unix.close w with _ -> ()) pipes ;

  let wall = Unix.gettimeofday () -. started in
  Printf.printf
    "busy=%-2d blocked=%-2d block=%4.1fs  cores=%-3d wall=%5.1fs  \
     worst wait %6.2fs  waits over 0.5s: %-4d  waiting %5.1fs (%.0f%%)\n%!"
    busy blocked_count block (Domain.recommended_domain_count ()) wall
    !worst !count !stalled (100. *. !stalled /. wall)
