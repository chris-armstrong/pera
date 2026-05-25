open Containers
open Pera_types

let name = "Anthropic"
let anthropic_api_url = "https://api.anthropic.com/v1/messages"
let anthropic_version = "2023-06-01"

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

(** Process the response body by feeding each chunk through the SSE/interpreter
    pipeline. Called by [on_chunk] from [Http_client.post_stream]. *)
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
    | Some (Error msg) -> Event_stream.close_error stream msg
    | None ->
        Event_stream.close_error stream
          "stream ended without a final message_stop event"
  in
  (on_chunk, finalise)

(** Build the HTTP request headers for the Anthropic API. *)
let build_headers api_key =
  [
    ("x-api-key", api_key);
    ("anthropic-version", anthropic_version);
    ("content-type", "application/json");
    ("accept", "text/event-stream");
  ]

(** Run the HTTP request and process the streaming response body. Returns
    [Ok ()] on success or [Error msg] on any failure. *)
let do_request ~env ~model ~context ~options ~sw stream =
  let open Result.Syntax in
  let* api_key =
    Sys.getenv_opt "ANTHROPIC_API_KEY"
    |> Option.to_result "ANTHROPIC_API_KEY environment variable is not set"
  in
  let request_body = build_request_body ~model ~context ~options in
  let request_body_str = Yojson.Safe.to_string request_body in
  let headers = build_headers api_key in
  let on_chunk, finalise = process_chunks stream in
  let* () =
    Http_client.post_stream ~env ~sw ~headers ~body:request_body_str ~on_chunk
      anthropic_api_url
    |> Result.map_error Http_client.error_to_string
  in
  Ok (finalise ())

let stream_simple ~env ~model ~context ~options ~sw =
  let stream :
      (Types.assistant_message_event, Types.assistant_message) Event_stream.t =
    Event_stream.create ~capacity:32
  in
  let run_request () =
    match do_request ~env ~model ~context ~options ~sw stream with
    | Ok () -> ()
    | Error msg -> Event_stream.close_error stream msg
  in
  Eio.Fiber.fork ~sw run_request;
  stream
