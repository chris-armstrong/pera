open Containers
open Pera_types

let name = "Anthropic"
let anthropic_api_url = "https://api.anthropic.com/v1/messages"
let anthropic_version = "2023-06-01"

(** Render a [Provider.message] to the Anthropic messages array format. *)
let message_to_json = function
  | Provider.UserMessage { role; content } ->
      let content_json =
        List.map
          (function
            | Types.UText text ->
                `Assoc [ ("type", `String "text"); ("text", `String text) ]
            | Types.UImage { url; media_type } ->
                `Assoc
                  [
                    ("type", `String "image");
                    ( "source",
                      `Assoc
                        [
                          ("type", `String "url");
                          ("url", `String url);
                          ("media_type", `String media_type);
                        ] );
                  ])
          content
      in
      `Assoc [ ("role", `String role); ("content", `List content_json) ]
  | Provider.AssistantMessage { content; _ } ->
      let content_json =
        List.map
          (function
            | Types.AText text ->
                `Assoc [ ("type", `String "text"); ("text", `String text) ]
            | Types.AThinking { text; _ } ->
                `Assoc
                  [ ("type", `String "thinking"); ("thinking", `String text) ]
            | Types.AToolCall { id; name; arguments } ->
                `Assoc
                  [
                    ("type", `String "tool_use");
                    ("id", `String id);
                    ("name", `String name);
                    ("input", arguments);
                  ])
          content
      in
      `Assoc [ ("role", `String "assistant"); ("content", `List content_json) ]

(** Render a [Provider.tool_schema] to the Anthropic tools array format. *)
let tool_to_json (tool : Provider.tool_schema) =
  `Assoc
    [
      ("name", `String tool.name);
      ("description", `String tool.description);
      ("input_schema", Json_schema.to_json tool.schema);
    ]

(** Build the JSON request body for the Anthropic messages API. *)
let build_request_body ~model ~context ~options =
  let open Provider in
  let messages_json = List.map message_to_json context.messages in
  let base_fields =
    [
      ("model", `String model.Types.id);
      ("max_tokens", `Int options.max_tokens);
      ("stream", `Bool true);
      ("messages", `List messages_json);
    ]
  in
  let with_system =
    if String.is_empty context.system then base_fields
    else base_fields @ [ ("system", `String context.system) ]
  in
  let with_tools =
    if List.is_empty context.tools then with_system
    else
      with_system @ [ ("tools", `List (List.map tool_to_json context.tools)) ]
  in
  let with_temperature =
    match options.temperature with
    | None -> with_tools
    | Some t -> with_tools @ [ ("temperature", `Float t) ]
  in
  `Assoc with_temperature

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
