open Core

(* Wrapper around integers and classes which identifies a spill slot *)
type t = int * int [@@deriving sexp, compare, equal]

module Set : Set.S with type Elt.t := t
module Map : Map.S with type Key.t := t
module Map_with_default : Map_with_default.S with type Key.t := t
