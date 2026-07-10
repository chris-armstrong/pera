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
  api_keys:(string * string) list ->
  base_url:string ->
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  t
(** [create ~registry ~api_keys ~base_url ~env ~sw] iterates the registry. For
    each [(api_name, (module P : Connector.S))] it looks up [api_name] in
    [api_keys] (an association list of connector name -> API key); connectors
    with no key in [api_keys] are skipped. For the rest:
    - [let inst = P.create ~api_key ~base_url ~env ~sw]
    - [let fn ~model ~context ~options ~sw = P.stream_simple inst ~model
       ~context ~options ~sw]
    - [(api_name, fn)] is added to the list.

    [base_url] is forwarded to every connector's [create]. Connectors that don't
    need it (e.g. Anthropic) may ignore it.

    Passing a single key to every connector would fan one provider's credential
    out to all of them (e.g. an OpenAI request authenticated with the Anthropic
    key); the per-connector [api_keys] list prevents that.

    The provider instances are created eagerly and live as long as [sw]. *)

val stream_fn : t -> Agent_types.stream_fn
(** [stream_fn adapter] returns an {!Agent_types.stream_fn} that dispatches by
    [model.protocol] to the pre-built closure.

    Unknown [model.protocol] values produce an {!Pera_connector.Event_stream.t}
    that immediately closes with an error message containing the unknown API
    name. *)
