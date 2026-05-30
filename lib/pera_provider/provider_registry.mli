(** Provider registry — maps model.api strings to (module Provider.S) values.

    An immutable, pure-functional registry built explicitly at startup. No
    global state. Provides lookup by model.api and helpers to register and
    enumerate named providers. *)

type t
(** An immutable registry mapping provider names (model.api strings) to provider
    modules. *)

val empty : t
(** [empty] is a fresh, empty registry. *)

val register : t -> name:string -> (module Provider.S) -> t
(** [register registry ~name provider] returns a new registry with the named
    provider added. If [name] is already registered, the registry is returned
    unchanged (first-write-wins). *)

val lookup : t -> api:string -> (module Provider.S) option
(** [lookup registry ~api] returns the provider registered under [api], or
    [None] if no provider is registered under that name. *)

val to_list : t -> (string * (module Provider.S)) list
(** [to_list registry] returns the full registry contents as an association
    list. The order is insertion order (most recently registered first). *)
