(** Provider adapter — binds a {!Pera_connector.Connector_registry.t} (and env +
    switch) into an {!Agent_types.stream_fn} closure suitable for
    {!Agent_loop.agent_loop_config}.

    Eager creation at {!create} time: iterates the registry, calls each
    provider's [create], and builds a pre-wired closure. No mutex, no lazy
    loading. Provider instances live as long as the adapter's [sw]. *)

type t
(** Opaque adapter type. Internally an association list of
    [(api_name, Agent_types.stream_fn)] closures built at {!create} time. *)

val create :
  registry:Pera_connector.Connector_registry.t ->
  api_key:string ->
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  t
(** [create ~registry ~api_key ~env ~sw] iterates the registry. For each
    [(api_name, (module P : Connector.S))]:
    - [let inst = P.create ~api_key ~env ~sw]
    - [let fn ~model ~context ~options ~sw = P.stream_simple inst ~model
       ~context ~options ~sw]
    - [(api_name, fn)] is added to the list.

    The provider instances are created eagerly and live as long as [sw]. *)

val stream_fn : t -> Agent_types.stream_fn
(** [stream_fn adapter] returns an {!Agent_types.stream_fn} that dispatches by
    [model.api] to the pre-built closure.

    Unknown [model.api] values produce an {!Pera_connector.Event_stream.t} that
    immediately closes with an error message containing the unknown API name. *)
