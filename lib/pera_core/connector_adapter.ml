open Containers

type entry = { api_name : string; fn : Agent_types.stream_fn }
(** Internal entry: a pre-built stream_fn closure paired with its api name. *)

type t = entry list
(** The adapter is an immutable list of entries, built eagerly at create. *)

(** Build one adapter entry from a registry pair. *)
let build_entry ~api_key ~env ~sw (api_name, (module P : Pera_connector.Connector.S)) =
  let inst = P.create ~api_key ~env ~sw in
  let fn ~model ~context ~options ~sw =
    P.stream_simple inst ~model ~context ~options ~sw
  in
  { api_name; fn }

(** Create an event stream that immediately closes with an error message. *)
let error_stream ~sw api_name =
  let stream = Pera_connector.Event_stream.create ~capacity:32 in
  let msg = Printf.sprintf "Unknown API: %s" api_name in
  Eio.Fiber.fork ~sw (fun () ->
      Pera_connector.Event_stream.close_internal_error stream msg);
  stream

let create ~registry ~api_key ~env ~sw =
  let providers = Pera_connector.Connector_registry.to_list registry in
  List.map (build_entry ~api_key ~env ~sw) providers

let stream_fn adapter =
 fun ~model ~context ~options ~sw ->
  let api_name = model.Pera_types.Types.api in
  match List.find_opt (fun e -> String.equal e.api_name api_name) adapter with
  | Some entry -> entry.fn ~model ~context ~options ~sw
  | None -> error_stream ~sw api_name
