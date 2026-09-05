(* Read another process's runtime events and report what its runtime
   spent time in.

   Every observer so far has been inside the process, and during a
   freeze every thread of it stops -- including one that only spins on
   the clock. So the question "what is it doing while stopped" cannot
   be answered from within. `runtime_events` writes to a ring buffer
   this process can read from outside, so it keeps running when the
   target does not.

   Usage: pauses <events dir> <pid> <seconds to watch> *)

let () =
  let dir = Sys.argv.(1) in
  let pid = int_of_string Sys.argv.(2) in
  let watch = float_of_string Sys.argv.(3) in

  (* The target may not have created its ring yet. *)
  let rec cursor_of tries =
    match Runtime_events.create_cursor (Some (dir, pid)) with
    | c -> c
    | exception e ->
      if tries = 0 then raise e
      else ( Unix.sleepf 0.2 ; cursor_of (tries - 1) )
  in
  let cursor = cursor_of 50 in

  let open_at : (int * Runtime_events.runtime_phase, int64) Hashtbl.t =
    Hashtbl.create 64 in
  let total : (Runtime_events.runtime_phase, float) Hashtbl.t =
    Hashtbl.create 64 in
  let longest : (Runtime_events.runtime_phase, float) Hashtbl.t =
    Hashtbl.create 64 in
  let count : (Runtime_events.runtime_phase, int) Hashtbl.t =
    Hashtbl.create 64 in

  let runtime_begin domain ts phase =
    Hashtbl.replace open_at (domain, phase)
      (Runtime_events.Timestamp.to_int64 ts)
  in
  let runtime_end domain ts phase =
    match Hashtbl.find_opt open_at (domain, phase) with
    | None -> ()
    | Some t0 ->
      Hashtbl.remove open_at (domain, phase) ;
      let ns =
        Int64.to_float (Int64.sub (Runtime_events.Timestamp.to_int64 ts) t0)
      in
      let s = ns /. 1e9 in
      let prev = try Hashtbl.find total phase with Not_found -> 0.0 in
      Hashtbl.replace total phase (prev +. s) ;
      let worst = try Hashtbl.find longest phase with Not_found -> 0.0 in
      if s > worst then Hashtbl.replace longest phase s ;
      let n = try Hashtbl.find count phase with Not_found -> 0 in
      Hashtbl.replace count phase (n + 1) ;
      (* A span of over a second is the thing being hunted, so say when
         it happened and in which domain as well as counting it. *)
      if s > 1.0 then
        Printf.printf "PAUSE %-28s %6.2fs in domain %d\n%!"
          (Runtime_events.runtime_phase_name phase) s domain
  in

  let callbacks =
    Runtime_events.Callbacks.create ~runtime_begin ~runtime_end ()
  in

  let started = Unix.gettimeofday () in
  ( try
      while Unix.gettimeofday () -. started < watch do
        ignore (Runtime_events.read_poll cursor callbacks None) ;
        Unix.sleepf 0.05
      done
    with e -> Printf.printf "consumer stopped: %s\n%!" (Printexc.to_string e) ) ;

  Printf.printf "\n%-30s %8s %10s %10s\n" "phase" "count" "total" "longest" ;
  Hashtbl.iter
    (fun phase t ->
      let n = try Hashtbl.find count phase with Not_found -> 0 in
      let w = try Hashtbl.find longest phase with Not_found -> 0.0 in
      if t > 0.05 || w > 0.5 then
        Printf.printf "%-30s %8d %9.2fs %9.2fs\n"
          (Runtime_events.runtime_phase_name phase) n t w)
    total ;
  Printf.printf "%!"
