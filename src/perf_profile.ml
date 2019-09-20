(**************************************************************************)
(*                                                                        *)
(*                                 OCamlFDO                               *)
(*                                                                        *)
(*                     Greta Yorsh, Jane Street Europe                    *)
(*                                                                        *)
(*   Copyright 2019 Jane Street Group LLC                                 *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)
(* Perf profile format as output of perf script -F pid,ip,brstack *)

open Core

let verbose = ref false

type mispredict_flag =
  | M
  | P
  | NOT_SUPPORTED
[@@deriving compare, sexp]

let mispredicted = function
  | M -> true
  | _ -> false

type br = {
  from_addr : Addr.t;
  to_addr : Addr.t;
  mispredict : mispredict_flag;
  index : int;
      (* Position on the stack, with 0 being the most recent branch. This
         field is only used for only for validation. *)
      (* cycles : int; *)
}
[@@deriving compare, sexp]

type sample = {
  ip : Addr.t;
  (* instruction pointer where the sample was taken *)
  brstack : br list; (* branch stack is the last branch record (LBR) *)
}
[@@deriving compare, sexp]

type t = sample list [@@deriving compare, sexp]

let parse_br index s =
  match String.split s ~on:'/' with
  | [ from_addr; to_addr; m; t; a; c ] ->
      let mispredict =
        match m with
        | "M" -> M
        | "P" -> P
        | "-" -> NOT_SUPPORTED
        | _ -> failwithf "Cannot parse mispredict flag %s in %s" m s ()
      in
      (* Parse and ignore t and a flags. *)
      ( match t with
      | "X" | "-" -> ()
      | _ -> failwithf "Cannot parse mispredict flag %s in %s" m s () );
      ( match a with
      | "A" | "-" -> ()
      | _ -> failwithf "Cannot parse mispredict flag %s in %s" a s () );

      (* Parse and ignore cycles. CR-soon gyorsh: use for optimizations. *)
      let _cycles = Int.of_string c in
      {
        from_addr = Int64.of_string from_addr;
        to_addr = Int64.of_string to_addr;
        index;
        mispredict;
      }
  | _ -> failwithf "Cannot parse %s\n" s ()

(* The most recent branch is printed first by perf script. The number of
   branch entries vary based on the underlying hardware. This function
   reverses the stack from its perf profile order. *)
let rec parse_brstack (index, brstack) row =
  match row with
  | [] -> (index, brstack)
  | hd :: tl ->
      let brstack = parse_br index hd :: brstack in
      parse_brstack (index + 1, brstack) tl

let split_on_whitespace row =
  let r = String.split ~on:' ' row in
  List.filter r ~f:(fun s -> not (String.is_empty s))

let hex s = if String.is_prefix ~prefix:"0x" s then s else "0x" ^ s

let row_to_sample ~keep_pid row =
  match split_on_whitespace row with
  | pid :: ip :: rest ->
      let pid = Int.of_string pid in
      if keep_pid pid then (
        if !verbose then printf "parsing ip %s\n" ip;
        let sample =
          {
            ip = Int64.of_string (hex ip);
            brstack = snd (parse_brstack (0, []) rest);
          }
        in
        if !verbose then (
          printf "raw brstack=%s\n" row;
          printf "parsed brstack=";
          List.iter sample.brstack ~f:(fun br ->
              printf "0x%Lx/0x%Lx " br.from_addr br.to_addr);
          printf "\n" );
        Some sample )
      else None
  | _ -> failwithf "Cannot parse %s\n" row ()

let pids = ref Int.Set.empty

let check_keep_pid ?expected_pid p =
  if !verbose then
    if not (Int.Set.mem !pids p) then (
      printf "Found new pid: %d\n" p;
      pids := Int.Set.add !pids p );
  match expected_pid with
  | None -> true
  | Some expected_pid ->
      if expected_pid = p then true
      else (
        if !verbose then
          printf "Mismatch pid: expected %L found %L\n" expected_pid p;
        false )

let perf_script_fold filename ~init ~f =
  let open Shexp_process in
  let open Shexp_process.Infix in
  let perf = eval (find_executable_exn "perf") in
  let args = [ "script"; "-F"; "pid,ip,brstack"; "-i"; filename ] in
  (* CR-soon gyorsh: lazy *)
  let f x y = return (f x y) in
  let t = eval (run perf args |- fold_lines ~init ~f) in
  t

let read ?(expected_pid = None) filename =
  if !verbose then
    printf
      "Reading perf profile generated by \"perf script -F pid,ip,brstack\" \
       from %s\n"
      filename;
  let keep_pid = check_keep_pid ?expected_pid in
  let f acc row =
    match row_to_sample ~keep_pid (String.strip row) with
    | None -> acc
    | Some sample -> sample :: acc
  in
  let t = perf_script_fold filename ~init:[] ~f in
  if !verbose then (
    Printf.printf !"%{sexp:t}\n" t;
    Printf.printf "Found pids:\n";
    Int.Set.iter !pids ~f:(fun pid -> Printf.printf "%d\n" pid) );
  t

type stats = {
  ignored : int;
  total : int;
  lbr : int;
}

let inc table key =
  Hashtbl.update table key ~f:(fun v ->
      Int64.(1L + Option.value ~default:0L v))

let aggregate_br prev cur is_last (aggregated : Aggregated_perf_profile.t) =
  (* Instructions executed between branches can be inferred from brstack *)
  match prev with
  | None -> ()
  | Some prev ->
      assert (prev.index = cur.index + 1);
      let from_addr = prev.to_addr in
      let to_addr = cur.from_addr in
      if !verbose then printf "trace 0x%Lx->0x%Lx\n" from_addr to_addr;

      (* There appear to be a problem with perf output: last LBR entry is
         repeated twice sometimes. It may be related to the recent problem
         mentioned in a patch for perf script: Fix LBR skid dump problems in
         brstackinsn https://github.com/torvalds/linux/commit
         /61f611593f2c90547cb09c0bf6977414454a27e6 *)
      let dup =
        prev.from_addr = cur.from_addr && prev.to_addr = cur.to_addr
      in
      let mis_prev = mispredicted prev.mispredict in
      let mis_cur = mispredicted cur.mispredict in
      let fallthrough_backwards = from_addr >= to_addr in
      if dup then
        if !verbose then
          printf
            "Duplicate entry in LBR: 0x%Lx->0x%Lx mis_prev=%b mis_cur=%b \
             last=%b (from_addr >= to_addr)=%b\n"
            prev.from_addr prev.to_addr mis_prev mis_cur is_last
            fallthrough_backwards;

      if dup && is_last then (
        if !verbose then
          printf "Duplicated last LBR entry is ignored: 0x%Lx->0x%Lx\n"
            from_addr to_addr;
        if not fallthrough_backwards then
          printf
            "Duplicate last entry without fallthrough backwards is \
             unexpected 0x%Lx->0x%Lx.\n"
            from_addr to_addr )
      else
        (* branches *)
        let key = (cur.from_addr, cur.to_addr) in
        inc aggregated.branches key;
        if mispredicted cur.mispredict then inc aggregated.mispredicts key;

        if fallthrough_backwards then
          printf
            "Malformed trace 0x%Lx->0x%Lx (from_addr >= to_addr), it was \
             not duplicated last entry.\n"
            from_addr to_addr
        else
          (* fallthrough traces *)
          let key = (from_addr, to_addr) in
          inc aggregated.traces key

(* CR-soon gyorsh: aggregate during parsing of perf profile *)
let rec aggregate_brstack prev brstack aggregated =
  match brstack with
  | [] -> ()
  | cur :: tl ->
      let is_last = List.is_empty tl in
      aggregate_br prev cur is_last aggregated;
      aggregate_brstack (Some cur) tl aggregated

let aggregate sample (aggregated : Aggregated_perf_profile.t) =
  inc aggregated.instructions sample.ip;
  aggregate_brstack None sample.brstack aggregated

let read_and_aggregate ?(expected_pid = None) filename =
  if !verbose then printf "Aggregate perf profile from %s.\n" filename;

  let aggregated = Aggregated_perf_profile.empty () in
  let keep_pid = check_keep_pid ?expected_pid in
  let empty_stats = { ignored = 0; total = 0; lbr = 0 } in
  let f stats row =
    match row_to_sample ~keep_pid row with
    | None ->
        { stats with ignored = stats.ignored + 1; total = stats.total + 1 }
    | Some sample ->
        aggregate sample aggregated;
        {
          stats with
          total = stats.total + 1;
          lbr = stats.lbr + List.length sample.brstack;
        }
  in
  let stats = perf_script_fold filename ~init:empty_stats ~f in
  if !verbose then (
    Printf.printf "Read %d samples with %d LBR entries\n" stats.total
      stats.lbr;
    let r = Float.(of_int stats.ignored * 100.0 / of_int stats.total) in
    Printf.printf "Ignored %d samples (%.1f)\n" stats.ignored r;
    Printf.printf "Found pids:\n";
    Int.Set.iter !pids ~f:(fun pid -> printf "%d\n" pid) );
  aggregated
