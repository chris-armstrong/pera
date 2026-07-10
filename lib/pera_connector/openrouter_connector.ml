open Containers
open Pera_types

let src = Logs.Src.create "pera.openrouter" ~doc:"Pera OpenRouter connector"

module Log = (val Logs.src_log src : Logs.LOG)

let name = "OpenRouter"

type t = {
  client : Http_client.t;
  api_key : string;
  compat : Openai_completions_request.compat;
  http_referer : string option;
  x_title : string option;
}

(* ── Request body ─────────────────────────────────────────────────────── *)

(** Reuse the OpenAI completions request builder. OpenRouter speaks the same
    wire format with a few extra optional fields. *)
let build_request_body = Openai_completions_request.build_request_body

(** Add OpenRouter-specific fields to the request body.

    - [reasoning]: when [thinking_budget_tokens] is set, adds
      ["reasoning": {"max_tokens": N}] so OpenRouter routes reasoning tokens
      correctly.
    - [cache_control]: when [cache_policy] is not [No_cache], adds
      ["cache_control": {"type": "ephemeral"}] to enable Anthropic-style
      automatic prompt caching for models routed through OpenRouter. *)
let add_openrouter_fields ~options body =
  match body with
  | `Assoc fields ->
      let with_reasoning =
        match options.Connector.thinking_budget_tokens with
        | Some n -> ("reasoning", `Assoc [ ("max_tokens", `Int n) ]) :: fields
        | None -> fields
      in
      let with_cache =
        match options.Connector.cache_policy with
        | Pera_types.Types.No_cache -> with_reasoning
        | Pera_types.Types.Conversation | Pera_types.Types.SystemAndToolsOnly ->
            ("cache_control", `Assoc [ ("type", `String "ephemeral") ])
            :: with_reasoning
      in
      `Assoc with_cache
  | other -> other

(* ── SSE interpretation ───────────────────────────────────────────────── *)

(** Reuse the OpenAI completions interpreter. OpenRouter's SSE stream is
    compatible; the [reasoning_field] compat setting handles the field-name
    difference ([reasoning] vs [reasoning_content]). *)
let process_chunks stream ~(compat : Openai_completions_request.compat) =
  let sse_state = ref Sse_parser.initial_state in
  let interp_state =
    ref
      (Openai_completions_interpreter.initial_state
         ~reasoning_field:compat.reasoning_field)
  in
  let done_message = ref None in
  let handle_ame ame =
    match ame with
    | Types.AME_done { message } ->
        done_message := Some (Ok message);
        Event_stream.close stream message
    | Types.AME_error { message; _ } ->
        done_message := Some (Error message);
        Event_stream.close_provider_error stream message
    | event -> Event_stream.push stream event
  in
  let handle_framed interp_state framed =
    let new_state, ames =
      Openai_completions_interpreter.feed !interp_state framed
    in
    interp_state := new_state;
    List.iter handle_ame ames
  in
  let on_chunk chunk =
    let new_sse_state, framed_events = Sse_parser.feed !sse_state chunk in
    sse_state := new_sse_state;
    List.iter (handle_framed interp_state) framed_events
  in
  let finalise () =
    let msg = "stream ended without a finish_reason or [DONE] sentinel" in
    match !done_message with
    | Some _ -> ()
    | None -> Event_stream.close_provider_error stream msg
  in
  (on_chunk, finalise)

(* ── Error detection ──────────────────────────────────────────────────── *)

(** OpenRouter returns errors as HTTP 200 with a JSON body containing an
    ["error"] field. Standard OpenAI-compatible providers use non-2xx status
    codes. We buffer the first chunk of every response and inspect it for the
    OpenRouter error shape before feeding it into the SSE pipeline. *)
let is_openrouter_error first_chunk =
  let trimmed = String.trim first_chunk in
  if
    (not (String.is_empty trimmed))
    && Char.equal (String.get trimmed 0) '{'
    && String.mem ~sub:"\"error\"" trimmed
  then
    match Yojson.Safe.from_string trimmed with
    | `Assoc fields -> (
        match List.assoc_opt ~eq:String.equal "error" fields with
        | Some (`Assoc err_fields) ->
            let msg =
              match List.assoc_opt ~eq:String.equal "message" err_fields with
              | Some (`String m) -> m
              | _ -> "unknown OpenRouter error"
            in
            let code =
              match List.assoc_opt ~eq:String.equal "code" err_fields with
              | Some (`Int c) -> Some c
              | _ -> None
            in
            Some (msg, code)
        | _ -> None)
    | _ -> None
    | exception _ -> None
  else None

(* ── HTTP request ─────────────────────────────────────────────────────── *)

let build_headers ~api_key ~http_referer ~x_title =
  let base =
    [
      ("authorization", "Bearer " ^ api_key);
      ("content-type", "application/json");
      ("accept", "text/event-stream");
    ]
  in
  let with_referer =
    match http_referer with
    | Some r -> ("http-referer", r) :: base
    | None -> base
  in
  match x_title with
  | Some t -> ("x-title", t) :: with_referer
  | None -> with_referer

let do_request ~provider ~model ~context ~options ~sw:_ stream =
  let request_body =
    build_request_body ~model ~context ~options ~compat:provider.compat
  in
  let request_body = add_openrouter_fields ~options request_body in
  let request_body_str = Yojson.Safe.to_string request_body in
  let full_url = provider.compat.base_url ^ "/v1/chat/completions" in
  Log.info (fun m -> m "POST %s  model=%s" full_url model.Types.id);
  let headers =
    build_headers ~api_key:provider.api_key ~http_referer:provider.http_referer
      ~x_title:provider.x_title
  in
  let on_chunk, finalise = process_chunks stream ~compat:provider.compat in
  (* Wrap [on_chunk] to detect OpenRouter errors on the first chunk. *)
  let first_chunk = ref true in
  let error_buf = ref "" in
  let wrapped_on_chunk chunk =
    if !first_chunk then (
      first_chunk := false;
      error_buf := !error_buf ^ chunk;
      (* Only inspect after we have enough data to parse JSON, or we've seen a
         non-JSON start. *)
      if String.length !error_buf > 0 then
        match is_openrouter_error !error_buf with
        | Some (msg, code) ->
            let full_msg =
              match code with
              | Some c -> Printf.sprintf "OpenRouter error %d: %s" c msg
              | None -> Printf.sprintf "OpenRouter error: %s" msg
            in
            Event_stream.close_provider_error stream full_msg
        | None -> on_chunk chunk)
    else on_chunk chunk
  in
  let http_result =
    Http_client.post_stream ~client:provider.client ~headers
      ~body:request_body_str ~on_chunk:wrapped_on_chunk "/chat/completions"
  in
  match http_result with
  | Error (Http_client.Transport_error te) ->
      Event_stream.close_error stream te.message Pera_types.Types.Transport
  | Error (Http_client.Http_error he) ->
      Event_stream.close_error stream
        (Http_client.request_error_to_string (Http_client.Http_error he))
        (Pera_types.Types.Http { status = he.status })
  | Ok () -> finalise ()

(* ── Lifecycle ────────────────────────────────────────────────────────── *)

let openrouter_compat base_url =
  {
    Openai_completions_request.base_url;
    reasoning_field = "reasoning";
    max_tokens_field = "max_tokens";
    require_tool_result_name = false;
    enable_thinking_field = None;
  }

let create ~api_key ~base_url ~env ~sw =
  let compat = openrouter_compat base_url in
  let http_referer = Sys.getenv_opt "OPENROUTER_HTTP_REFERER" in
  let x_title = Sys.getenv_opt "OPENROUTER_X_TITLE" in
  Log.debug (fun m -> m "base_url=%s" base_url);
  let client =
    match Http_client.create ~env ~sw base_url with
    | Ok c -> c
    | Error e ->
        failwith
          (Printf.sprintf "Openrouter_connector.create: %s"
             (Http_client.request_error_to_string e))
  in
  { client; api_key; compat; http_referer; x_title }

let create_from_env ~base_url ~env ~sw =
  Connector.create_from_env_var ~var_name:"OPENROUTER_API_KEY" ~create ~base_url
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
