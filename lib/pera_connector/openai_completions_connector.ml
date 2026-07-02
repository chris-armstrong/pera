open Containers
open Pera_types

let src =
  Logs.Src.create "pera.openai_completions"
    ~doc:"Pera OpenAI completions provider"

module Log = (val Logs.src_log src : Logs.LOG)

let name = "OpenAI"

type t = {
  client : Http_client.t;
  api_key : string;
  compat : Openai_completions_request.compat;
}

(** Build the JSON request body for the OpenAI chat-completions API. Delegates
    to [Openai_completions_request] which owns the serialisation logic. *)
let build_request_body = Openai_completions_request.build_request_body

(** Dispatch a single [Types.assistant_message_event] from the interpreter:
    terminal events (done/error) close the stream immediately so the caller
    unblocks without waiting for the HTTP connection to reach EOF. All other
    events are pushed into the stream. *)
let handle_ame stream done_message ame =
  match ame with
  | Types.AME_done { message } ->
      done_message := Some (Ok message);
      Event_stream.close stream message
  | Types.AME_error { message; _ } ->
      done_message := Some (Error message);
      Event_stream.close_provider_error stream message
  | event -> Event_stream.push stream event

(** Feed a single framed SSE event through the OpenAI interpreter and dispatch
    every resulting [Types.assistant_message_event]. *)
let handle_framed interp_state stream done_message framed =
  let new_state, ames =
    Openai_completions_interpreter.feed !interp_state framed
  in
  interp_state := new_state;
  List.iter (handle_ame stream done_message) ames

(** Feed a raw SSE chunk through the SSE parser and dispatch all framed events.
*)
let log_chunks = Option.is_some (Sys.getenv_opt "PERA_LOG_CHUNKS")

let process_chunk sse_state interp_state stream done_message chunk =
  if log_chunks then Log.warn (fun m -> m "chunk: %S" chunk);
  let new_sse_state, framed_events = Sse_parser.feed !sse_state chunk in
  sse_state := new_sse_state;
  List.iter (handle_framed interp_state stream done_message) framed_events

(** Build the on_chunk callback and finalise function for a streaming request.
    The on_chunk callback feeds raw chunks through the SSE/interpreter pipeline.
    The finalise function closes the stream based on the accumulated result. *)
let process_chunks stream ~(compat : Openai_completions_request.compat) =
  let sse_state = ref Sse_parser.initial_state in
  let interp_state =
    ref
      (Openai_completions_interpreter.initial_state
         ~reasoning_field:compat.reasoning_field)
  in
  let done_message = ref None in
  let on_chunk chunk =
    process_chunk sse_state interp_state stream done_message chunk
  in
  let finalise () =
    let msg = "stream ended without a finish_reason or [DONE] sentinel" in
    match !done_message with
    | Some _ -> () (* stream already closed in handle_ame *)
    | None -> Event_stream.close_provider_error stream msg
  in
  (on_chunk, finalise)

(** Build the HTTP request headers for the OpenAI API. *)
let build_headers api_key =
  [
    ("authorization", "Bearer " ^ api_key);
    ("content-type", "application/json");
    ("accept", "text/event-stream");
  ]

(** Run the HTTP request using the persistent provider client and process the
    streaming response body. Closes the stream when done. *)
let do_request ~provider ~model ~context ~options ~sw:_ stream =
  let request_body =
    build_request_body ~model ~context ~options ~compat:provider.compat
  in
  let request_body_str = Yojson.Safe.to_string request_body in
  let full_url = provider.compat.base_url ^ "/v1/chat/completions" in
  Log.info (fun m -> m "POST %s  model=%s" full_url model.Types.id);
  if log_chunks then Log.debug (fun m -> m "request body: %s" request_body_str);
  let headers = build_headers provider.api_key in
  let on_chunk, finalise = process_chunks stream ~compat:provider.compat in
  let http_result =
    Http_client.post_stream ~client:provider.client ~headers
      ~body:request_body_str ~on_chunk "/chat/completions"
  in
  match http_result with
  | Error (Http_client.Transport_error te) ->
      Event_stream.close_error stream te.message Pera_types.Types.Transport
  | Error (Http_client.Http_error he) ->
      Event_stream.close_error stream
        (Http_client.request_error_to_string (Http_client.Http_error he))
        (Pera_types.Types.Http { status = he.status })
  | Ok () -> finalise ()

let create ~api_key ~base_url ~env ~sw =
  let base_compat =
    match Sys.getenv_opt "OPENAI_COMPAT" with
    | Some preset -> Openai_completions_request.compat_of_string preset
    | None -> Openai_completions_request.default_compat
  in
  let compat = { base_compat with base_url } in
  Log.debug (fun m ->
      m "OPENAI_COMPAT=%s  base_url=%s"
        (Option.value ~default:"(unset)" (Sys.getenv_opt "OPENAI_COMPAT"))
        base_url);
  let client =
    match Http_client.create ~env ~sw base_url with
    | Ok c -> c
    | Error e ->
        failwith
          (Printf.sprintf "Openai_completions_connector.create: %s"
             (Http_client.request_error_to_string e))
  in
  { client; api_key; compat }

let create_from_env ~base_url ~env ~sw =
  Connector.create_from_env_var ~var_name:"OPENAI_API_KEY" ~create ~base_url
    ~env ~sw

let stream_simple provider ~model ~context ~options ~sw =
  let stream :
      (Types.assistant_message_event, Types.assistant_message) Event_stream.t =
    Event_stream.create ~capacity:32
  in
  let run_request () =
    do_request ~provider ~model ~context ~options ~sw stream
  in
  Eio.Fiber.fork ~sw run_request;
  stream
