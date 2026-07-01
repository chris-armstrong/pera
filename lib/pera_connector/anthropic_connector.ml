open Containers
open Pera_types

let name = "Anthropic"
let anthropic_messages_path = "/v1/messages"
let anthropic_version = "2023-06-01"

type t = { client : Http_client.t; api_key : string }

(** Build the JSON request body for the Anthropic messages API. Delegates to
    [Anthropic_request] which owns the serialisation logic. *)
let build_request_body = Anthropic_request.build_request_body

(** Dispatch a single [Types.assistant_message_event] from the interpreter:
    terminal events (done/error) resolve [done_message]; all others are pushed
    into the stream. *)
let handle_ame stream done_message ame =
  match ame with
  | Types.AME_done { message } -> done_message := Some (Ok message)
  | Types.AME_error { message; _ } -> done_message := Some (Error message)
  | event -> Event_stream.push stream event

(** Feed a single framed SSE event through the Anthropic interpreter and
    dispatch every resulting [Types.assistant_message_event]. *)
let handle_framed interp_state stream done_message framed =
  let new_state, ames = Anthropic_interpreter.feed !interp_state framed in
  interp_state := new_state;
  List.iter (handle_ame stream done_message) ames

(** Feed a raw SSE chunk through the SSE parser and dispatch all framed events.
*)
let process_chunk sse_state interp_state stream done_message chunk =
  let new_sse_state, framed_events = Sse_parser.feed !sse_state chunk in
  sse_state := new_sse_state;
  List.iter (handle_framed interp_state stream done_message) framed_events

(** Build the on_chunk callback and finalise function for a streaming request.
    The on_chunk callback feeds raw chunks through the SSE/interpreter pipeline.
    The finalise function closes the stream based on the accumulated result. *)
let process_chunks stream =
  let sse_state = ref Sse_parser.initial_state in
  let interp_state = ref Anthropic_interpreter.initial_state in
  let done_message = ref None in
  let on_chunk chunk =
    process_chunk sse_state interp_state stream done_message chunk
  in
  let finalise () =
    match !done_message with
    | Some (Ok message) -> Event_stream.close stream message
    | Some (Error msg) -> Event_stream.close_provider_error stream msg
    | None ->
        Event_stream.close_provider_error stream
          "stream ended without a final message_stop event"
  in
  (on_chunk, finalise)

(** Build the HTTP request headers for the Anthropic API. *)
let build_headers ?(thinking = false) api_key =
  let base =
    [
      ("x-api-key", api_key);
      ("anthropic-version", anthropic_version);
      ("content-type", "application/json");
      ("accept", "text/event-stream");
    ]
  in
  if thinking then ("anthropic-beta", "interleaved-thinking-2025-05-14") :: base
  else base

(** Run the HTTP request using the persistent provider client and process the
    streaming response body. Closes the stream when done. *)
let do_request ~provider ~model ~context ~options ~sw:_ stream =
  let request_body = build_request_body ~model ~context ~options in
  let request_body_str = Yojson.Safe.to_string request_body in
  let headers =
    build_headers
      ~thinking:(Option.is_some options.thinking_budget_tokens)
      provider.api_key
  in
  let on_chunk, finalise = process_chunks stream in
  let http_result =
    Http_client.post_stream ~client:provider.client ~headers
      ~body:request_body_str ~on_chunk anthropic_messages_path
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
  let client =
    match Http_client.create ~env ~sw base_url with
    | Ok c -> c
    | Error e ->
        failwith
          (Printf.sprintf "Anthropic_connector.create: %s"
             (Http_client.request_error_to_string e))
  in
  { client; api_key }

let create_from_env ~base_url ~env ~sw =
  Connector.create_from_env_var ~var_name:"ANTHROPIC_API_KEY" ~create
    ~base_url ~env ~sw

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
