open Core
open Dbg
open Loc
open Func
module Cfg_with_layout = Ocamlcfg.Cfg_with_layout
module Cfg = Ocamlcfg.Cfg

let verbose = ref false

type t =
  { (* map raw addresses to locations *)
    addr2loc : Loc.t Hashtbl.M(Addr).t;
    (* map func name to func id *)
    name2id : int Hashtbl.M(String).t;
    (* map func id to func info *)
    functions : Func.t Hashtbl.M(Int).t;
    (* map func id to cfg_info of that function. *)
    (* sparse, only holds functions that have cfg *and* execounts. *)
    (* logically it should be defined inside Func.t but it creates a cyclic
       dependency between . The advantage of the current design is smaller
       space that a Func takes if it doesn't have a cfg_info *)
    execounts : Cfg_info.blocks Hashtbl.M(Int).t;
    (* map name of compilation unit or function to its md5 digest. Currently
       contains only crcs of linear IR. Not using Caml.Digest.t because it
       does not have sexp. Not using Core's Digest because digests generated
       by the compiler using Caml.Digest might disagree. *)
    crcs : Md5.t Hashtbl.M(String).t
  }
[@@deriving sexp]

let mk size =
  { addr2loc = Hashtbl.create ~size (module Addr);
    name2id = Hashtbl.create (module String);
    functions = Hashtbl.create (module Int);
    execounts = Hashtbl.create (module Int);
    crcs = Hashtbl.create (module String)
  }

let get_func t addr =
  match Hashtbl.find t.addr2loc addr with
  | None ->
      printf "Not found any cached location for address 0x%Lx\n" addr;
      assert false
  | Some loc -> (
      match loc.rel with
      | None -> None
      | Some rel ->
          let id = rel.id in
          let func = Hashtbl.find_exn t.functions id in
          Some func )

(* Partition aggregated_perf to functions and calculate total execution
   counts of each function. Total execution count of a function is determined
   from the execution counts of samples contained in this function. It uses
   LBR info: if a branch source or target is contained in the function, it
   contributes to execution count of the function. It does not use the CFG.
   In particular, it does not count instructions that can be traced using
   LBR. The advantage is that we can compute it for non-OCaml functions. *)
let create_func_execounts t (agg : Aggregated_perf_profile.t) =
  Hashtbl.iteri agg.instructions ~f:(fun ~key ~data ->
      match get_func t key with
      | None -> ()
      | Some func ->
          func.count <- Int64.(func.count + data);
          Hashtbl.add_exn func.agg.instructions ~key ~data);
  let process (from_addr, to_addr) update =
    match (get_func t from_addr, get_func t to_addr) with
    | None, None -> ()
    | None, Some to_func -> update to_func
    | Some from_func, None -> update from_func
    | Some from_func, Some to_func ->
        if from_func.id = to_func.id then update to_func
        else (
          (* interprocedural branch: add to both functions *)
          update from_func;
          update to_func )
  in
  Hashtbl.iteri agg.branches ~f:(fun ~key ~data ->
      let mispredicts =
        Option.value (Hashtbl.find agg.mispredicts key) ~default:0L
      in
      let update_br func =
        func.count <- Int64.(func.count + data);
        Hashtbl.add_exn func.agg.branches ~key ~data;
        if Int64.(mispredicts > 0L) then
          Hashtbl.add_exn func.agg.mispredicts ~key ~data:mispredicts
      in
      process key update_br);
  Hashtbl.iteri agg.traces ~f:(fun ~key ~data ->
      (* traces don't contribute to func's total count because it is account
         for in branches. *)
      let update_tr func = Hashtbl.add_exn func.agg.traces ~key ~data in
      process key update_tr)

(* Find or add the function and return its id *)
let get_func_id t ~name ~start ~finish =
  match Hashtbl.find t.name2id name with
  | None ->
      let id = Hashtbl.length t.functions in
      let func = Func.mk ~id ~name ~start ~finish in
      Hashtbl.add_exn t.functions ~key:id ~data:func;
      Hashtbl.add_exn t.name2id ~key:name ~data:id;
      func.id
  | Some id ->
      let func = Hashtbl.find_exn t.functions id in
      assert (func.id = id);
      assert (String.equal func.name name);
      assert (Addr.equal func.start start);
      assert (Addr.equal func.finish finish);
      func.id

let decode_addr t addr interval dbg =
  let open Loc in
  let loc =
    match interval with
    | None ->
        if !verbose then
          printf "Cannot find function symbol containing 0x%Lx\n" addr;
        { addr; rel = None; dbg = None }
    | Some interval ->
        let open Intervals in
        let name = interval.v in
        let start = interval.l in
        let finish = interval.r in
        let offset =
          match Int64.(to_int (addr - start)) with
          | None ->
              Report.user_error "Offset too big: 0x%Lx"
                Addr.(addr - start)
                ()
          | Some offset ->
              assert (offset >= 0);
              offset
        in
        let id = get_func_id t ~name ~start ~finish in
        let rel = Some { id; offset; label = None } in
        let dbg =
          match dbg with
          | None ->
              if !verbose then
                Printf.printf "Elf location NOT FOUND at 0x%Lx\n" addr;
              None
          | Some dbg ->
              if !verbose then
                Printf.printf "%Lx:%Lx:%s:%d\n" addr start dbg.file dbg.line;

              (* Check that the filename has supported suffix and return it. *)
              if Filenames.(compare Linear ~expected:name ~actual:dbg.file)
              then (
                (* Set has_linearids of this function *)
                let func = Hashtbl.find_exn t.functions id in
                func.has_linearids <- true;
                Some dbg )
              else None
        in
        if !verbose then printf "addr2loc adding addr=0x%Lx\n" addr;
        { addr; rel; dbg }
  in
  Hashtbl.add_exn t.addr2loc ~key:addr ~data:loc

let create locations (agg : Aggregated_perf_profile.t) =
  if !verbose then printf "Decoding perf profile.\n";

  (* Collect all addresses that need decoding. Mispredicts and traces use the
     same addresses as branches, so no need to add them *)
  (* Overapproximation of number of different addresses for creating hashtbl *)
  let size =
    Hashtbl.length agg.instructions + (Hashtbl.length agg.branches * 2)
  in
  let addresses = Hashtbl.create ~size (module Addr) in
  let add key =
    if not (Hashtbl.mem addresses key) then (
      if !verbose then printf "Adding key 0x%Lx\n" key;
      Hashtbl.set addresses ~key ~data:None )
    else if !verbose then printf "Found key 0x%Lx\n" key
  in
  let add2 (fa, ta) =
    add fa;
    add ta
  in
  Hashtbl.iter_keys agg.instructions ~f:add;
  Hashtbl.iter_keys agg.branches ~f:add2;

  (* A key may be used multiple times in keys of t.instruction and t.branches *)
  let len = Hashtbl.length addresses in
  if !verbose then printf "size=%d,len=%d\n" size len;
  assert (len <= size);
  let t = mk len in
  (* Resolve all addresses seen in samples in one pass over the binary. *)
  Elf_locations.resolve_all locations addresses;

  (* Decode all locations: map addresses to locations. *)
  Hashtbl.iteri addresses ~f:(fun ~key:addr ~data:dbg ->
      (* this is cached using interval tree *)
      let interval =
        Elf_locations.resolve_function_containing locations
          ~program_counter:addr
      in
      decode_addr t addr interval dbg);
  create_func_execounts t agg;
  t

let read filename =
  if !verbose then
    printf "Reading aggregated decoded profile from %s\n" filename;
  let t =
    match Parsexp_io.load (module Parsexp.Single) ~filename with
    | Ok t_sexp -> t_of_sexp t_sexp
    | Error error ->
        Parsexp.Parse_error.report Caml.Format.std_formatter error ~filename;
        Report.user_error "Cannot parse aggregated decoded profile file"
  in
  if !verbose then printf !"Aggregated decoded profile:\n%{sexp:t}\n" t;
  t

let write t filename =
  if !verbose then
    printf "Writing aggregated decoded profile to %s\n" filename;
  let chan = Out_channel.create filename in
  Printf.fprintf chan !"%{sexp:t}\n" t;
  Out_channel.close chan

let top_functions t =
  (* Sort functions using preliminary function-level execution counts in
     descending order. *)
  let sorted = List.sort (Hashtbl.data t.functions) ~compare:Func.compare in
  let fl = List.map sorted ~f:(fun func -> func.name) in
  fl

(* Translate linear ids of this function's locations to cfg labels within
   this function, find the corresponding basic blocks and update their
   block_info. Perform lots of sanity checks to make sure the location of the
   execounts match the instructions in the cfg. *)
let create_cfg_info t func cl =
  let get_loc addr = Hashtbl.find_exn t.addr2loc addr in
  let i = Cfg_info.create cl func in
  (* Associate instruction counts with basic blocks *)
  Hashtbl.iteri func.agg.instructions ~f:(fun ~key ~data ->
      let loc = get_loc key in
      Cfg_info.record_ip i ~loc ~data);

  (* Associate fall-through trace counts with basic blocks *)
  Hashtbl.iteri func.agg.traces ~f:(fun ~key ~data ->
      let from_addr, to_addr = key in
      let from_loc = get_loc from_addr in
      let to_loc = get_loc to_addr in
      Cfg_info.record_trace i ~from_loc ~to_loc ~data);
  ( if !verbose then
    let total_traces =
      List.fold (Hashtbl.data func.agg.traces) ~init:0L ~f:Int64.( + )
    in
    let ratio =
      if Int64.(total_traces > 0L) then
        Int64.(func.malformed_traces * 100L / total_traces)
      else 0L
    in
    printf "Found %Ld malformed traces out of %Ld (%Ld%%)\n"
      func.malformed_traces total_traces ratio );

  (* Associate branch counts with basic blocks *)
  Hashtbl.iteri func.agg.branches ~f:(fun ~key ~data ->
      let mispredicts =
        Option.value (Hashtbl.find func.agg.mispredicts key) ~default:0L
      in
      let from_addr, to_addr = key in
      let from_loc = get_loc from_addr in
      let to_loc = get_loc to_addr in
      Cfg_info.record_branch i ~from_loc ~to_loc ~data ~mispredicts);
  Cfg_info.blocks i

(* Compute detailed execution counts for function [name] using its CFG *)
let add t name cl =
  match Hashtbl.find t.name2id name with
  | None ->
      if !verbose then printf "Not found profile for %s with cfg.\n" name;
      None
  | Some id ->
      let func = Hashtbl.find_exn t.functions id in
      if Int64.(func.count > 0L) && func.has_linearids then (
        if !verbose then (
          printf "compute_cfg_execounts for %s\n" name;
          Cfg_with_layout.print_dot cl "execount" );
        let cfg_info = create_cfg_info t func cl in
        Hashtbl.add_exn t.execounts ~key:id ~data:cfg_info;
        Some cfg_info )
      else None
