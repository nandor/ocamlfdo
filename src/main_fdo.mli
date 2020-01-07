val optimize :
  string list ->
  fdo_profile:string option ->
  reorder_blocks:Config_reorder.Reorder_blocks.t ->
  extra_debug:bool ->
  crc_config:Crcs.Config.t ->
  report:bool ->
  unit

val compile :
  string list option ->
  fdo_profile:string option ->
  reorder_blocks:Config_reorder.Reorder_blocks.t ->
  extra_debug:bool ->
  crc_config:Crcs.Config.t ->
  report:bool ->
  unit

val check : string list -> unit

val decode :
  string list ->
  binary_filename:string ->
  reorder_functions:Config_reorder.Reorder_functions.t ->
  linker_script_hot_filename:string option ->
  output_filename:string option ->
  write_linker_script_hot:bool ->
  ignore_buildid:bool ->
  expected_pids:int list ->
  check:bool ->
  write_aggregated_profile:bool ->
  read_aggregated_perf_profile:bool ->
  crc_config:Crcs.Config.t ->
  unit

val merge :
  string list ->
  read_aggregated_perf_profile:bool ->
  crc_config:Crcs.Config.t ->
  ignore_buildid:bool ->
  output_filename:string ->
  unit

val dump : string list -> dot:bool -> show_instr:bool -> unit

val verbose : bool ref