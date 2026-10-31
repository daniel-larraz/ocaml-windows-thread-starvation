(* Reproducer for ocaml/ocaml#15042: stop-the-world sections stall for
   seconds on Windows when there are more runnable domains than processors.

   Usage: stall [allocating] [sleeping] [seconds]

   [allocating] domains allocate short-lived blocks, so that minor
   collections, and thus stop-the-world sections, happen all the time.
   [sleeping] domains loop on [Unix.sleepf 0.01], entering and leaving a
   blocking section. The main domain wakes up every 10 ms and measures how
   late it is; it can only be late by more than the timer resolution if it
   was held in a stop-the-world section.

   Defaults: twice as many allocating domains as there are processors
   available to the process, 3 sleeping domains, 20 seconds. *)

let stop = Atomic.make false

let allocating () =
  let keep = ref [] in
  while not (Atomic.get stop) do
    for _ = 1 to 200 do
      keep := Sys.opaque_identity (ref 0) :: !keep ;
      if List.length !keep > 400 then keep := []
    done
  done

let sleeping () =
  while not (Atomic.get stop) do Unix.sleepf 0.01 done

let () =
  let arg i default =
    if Array.length Sys.argv > i then int_of_string Sys.argv.(i) else default
  in
  let cpus = Domain.recommended_domain_count () in
  let allocating_n = arg 1 (2 * cpus) and sleeping_n = arg 2 3 in
  let seconds = float_of_int (arg 3 20) in
  Printf.printf "%d processors, %d allocating + %d sleeping domains, %.0fs\n%!"
    cpus allocating_n sleeping_n seconds ;
  let domains =
    List.init allocating_n (fun _ -> Domain.spawn allocating)
    @ List.init sleeping_n (fun _ -> Domain.spawn sleeping)
  in
  let start = Unix.gettimeofday () in
  let previous = ref start and worst = ref 0. and stalled = ref 0. in
  let buckets = [| 0.05; 0.1; 0.5; 1.; 2. |] in
  let counts = Array.make (Array.length buckets) 0 in
  while !previous -. start < seconds do
    Unix.sleepf 0.01 ;
    let now = Unix.gettimeofday () in
    let late = now -. !previous -. 0.01 in
    previous := now ;
    if late > !worst then worst := late ;
    if late > 0.05 then stalled := !stalled +. late ;
    Array.iteri (fun i b -> if late > b then counts.(i) <- counts.(i) + 1)
      buckets
  done ;
  Atomic.set stop true ;
  let join_start = Unix.gettimeofday () in
  List.iter Domain.join domains ;
  let join = Unix.gettimeofday () -. join_start in
  Printf.printf "worst stall %.3fs, %.1fs of %.0fs spent in stalls over 50ms\n"
    !worst !stalled seconds ;
  Array.iteri (fun i b -> Printf.printf "  stalls > %4.2fs: %d\n" b counts.(i))
    buckets ;
  Printf.printf "joining the domains took %.3fs; %d minor collections\n"
    join (Gc.quick_stat ()).Gc.minor_collections
