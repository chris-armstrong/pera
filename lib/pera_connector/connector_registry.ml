open Containers

(** Internal representation: an association list mapping connector API name
    (model.api string) to the first-class module. OCaml first-class modules
    cannot be stored in a Map (they are not comparable), so we use an
    association list. The list is short (2-3 connectors). *)

type t = (string * (module Connector.S)) list

let empty = []

let register t ~name provider =
  (* Only add if name is not already present (first-write-wins). *)
  if List.mem_assoc ~eq:String.equal name t then t else (name, provider) :: t

let lookup t ~api = List.assoc_opt ~eq:String.equal api t
let to_list t = t
