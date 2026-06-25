open Containers

type turn_script = {
  events : Pera_types.Types.assistant_message_event list;
  final : Pera_types.Types.assistant_message;
}

type error_script = {
  error_events : Pera_types.Types.assistant_message_event list;
  error_message : string;
}

type script = Turn of turn_script | Error of error_script

(** Module-level recording of all provider contexts received, in call order. *)
let recorded : Pera_connector.Connector.context list ref = ref []

let recorded_contexts () = List.rev !recorded
let reset_recorded () = recorded := []

(** Module-level recording of the API keys each [create] call received, in call
    order. Used to verify per-connector key routing in [Connector_adapter]. *)
let recorded_api_keys_ref : string list ref = ref []

let recorded_api_keys () = List.rev !recorded_api_keys_ref
let reset_recorded_api_keys () = recorded_api_keys_ref := []

let stream_fn_of_scripts ?pause scripts =
  let scripts_ref = ref scripts in
  fun ~model:_ ~context ~options:_ ~sw ->
    recorded := context :: !recorded;
    let script =
      match !scripts_ref with
      | [] -> failwith "Faux_provider: no more scripts"
      | s :: rest ->
          scripts_ref := rest;
          s
    in
    let stream = Pera_connector.Event_stream.create ~capacity:32 in
    Eio.Fiber.fork ~sw (fun () ->
        match
          match script with
          | Turn { events; final } ->
              List.iter
                (fun event ->
                  Pera_connector.Event_stream.push stream event;
                  Option.iter (fun f -> f ()) pause)
                events;
              Pera_connector.Event_stream.close stream final
          | Error { error_events; error_message } ->
              List.iter
                (fun event ->
                  Pera_connector.Event_stream.push stream event;
                  Option.iter (fun f -> f ()) pause)
                error_events;
              Pera_connector.Event_stream.close_error stream error_message
                Pera_types.Types.Transport
        with
        | () -> ()
        | exception exn -> (
            let err_msg = Printexc.to_string exn in
            try Pera_connector.Event_stream.close_internal_error stream err_msg
            with _ -> ()));
    stream

let as_provider scripts =
  let fn = stream_fn_of_scripts scripts in
  (module struct
    type t = unit

    let name = "Faux"
    let create ~api_key:k ~env:_ ~sw:_ =
      recorded_api_keys_ref := k :: !recorded_api_keys_ref;
      ()

    let stream_simple () ~model ~context ~options ~sw =
      fn ~model ~context ~options ~sw
  end : Pera_connector.Connector.S)
