(** Connector registry — maps model.api strings to (module Connector.S) values.

    An immutable, pure-functional registry built explicitly at startup. No
    global state. Provides lookup by model.api and helpers to register and
    enumerate named connectors. *)

type t
(** An immutable registry mapping connector names (model.api strings) to
    connector modules. *)

val empty : t
(** [empty] is a fresh, empty registry. *)

val register : t -> name:string -> (module Connector.S) -> t
(** [register registry ~name connector] returns a new registry with the named
    connector added. If [name] is already registered, the registry is returned
    unchanged (first-write-wins). *)

val lookup : t -> api:string -> (module Connector.S) option
(** [lookup registry ~api] returns the connector registered under [api], or
    [None] if no connector is registered under that name. *)

val to_list : t -> (string * (module Connector.S)) list
(** [to_list registry] returns the full registry contents as an association
    list. The order is insertion order (most recently registered first). *)
