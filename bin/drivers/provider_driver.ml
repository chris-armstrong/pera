open Containers
open Pera_provider
open Pera_types

let src = Logs.Src.create "pera.driver.provider" ~doc:"Provider driver"

module Log = (val Logs.src_log src : Logs.LOG)

(** Truncate a string to at most [max_len] characters, appending "..." if
    truncated. *)
let truncate max_len s =
  if String.length s <= max_len then s else String.sub s 0 max_len ^ "..."

(** Format an [assistant_message_event] as a human-readable one-liner for the
    driver output. *)
let describe_event = function
  | Types.AME_text_start _ -> "[text_start]"
  | Types.AME_text_delta { text; _ } ->
      Printf.sprintf "[text_delta] %s" (truncate 60 text)
  | Types.AME_thinking_start _ -> "[thinking_start]"
  | Types.AME_thinking_delta { text; _ } ->
      Printf.sprintf "[thinking_delta] %s" (truncate 60 text)
  | Types.AME_tool_call_start { name; id; _ } ->
      Printf.sprintf "[tool_call_start] name=%s id=%s" name id
  | Types.AME_tool_call_delta { index; arguments_fragment; _ } ->
      Printf.sprintf "[tool_call_delta] index=%d fragment=%s" index
        (truncate 40 arguments_fragment)
  | Types.AME_tool_call_end { index; partial } ->
      let args =
        match List.nth_opt partial.Types.content index with
        | Some (Types.AToolCall { arguments; _ }) ->
            Yojson.Safe.to_string arguments
        | _ -> "?"
      in
      Printf.sprintf "[tool_call_end] index=%d args=%s" index args
  | Types.AME_done _ -> "[done]"
  | Types.AME_error { message; _ } ->
      Printf.sprintf "[error] %s" (truncate 80 message)

(** Format the content of an assistant message for the summary line. *)
let summarise_content content =
  let format_block = function
    | Types.AText text -> Printf.sprintf "text(%d chars)" (String.length text)
    | Types.AThinking { text; _ } ->
        Printf.sprintf "thinking(%d chars)" (String.length text)
    | Types.AToolCall { name; arguments; _ } ->
        Printf.sprintf "tool_call(%s, args=%s)" name
          (Yojson.Safe.to_string arguments)
  in
  let blocks = List.map format_block content in
  if List.is_empty blocks then "(empty)" else String.concat ", " blocks

(** A simple weather-lookup tool used to demonstrate provider-level tool
    invocation. The driver does not implement the tool; it only exercises the
    provider's ability to request a call and parse the arguments. *)
let get_weather_tool =
  Provider.
    {
      name = "get_weather";
      description = "Get the current weather conditions for a location.";
      schema =
        Json_schema.object_
          ~properties:
            [
              ( "location",
                Json_schema.string ~description:"City name, e.g. \"Sydney, AU\""
                  () );
              ( "units",
                Json_schema.optional
                  (Json_schema.enum [ "celsius"; "fahrenheit" ]) );
            ]
          ~required:[ "location" ] ();
    }

let stop_reason_string = function
  | Types.EndTurn -> "end_turn"
  | Types.ToolUse -> "tool_use"
  | Types.MaxTokens -> "max_tokens"
  | Types.StopSequence -> "stop_sequence"
  | Types.Error -> "error"
  | Types.Aborted -> "aborted"

let run_default_scenario ~model_id ~prompt_text ~max_tokens =
  let model = Types.{ id = model_id; api = "anthropic" } in
  let user_msg =
    Types.{ role = "user"; content = [ Types.UText prompt_text ] }
  in
  let context =
    Provider.
      {
        system = "You are a helpful assistant.";
        messages = [ Provider.UserMessage user_msg ];
        tools = [ get_weather_tool ];
        thinking = false;
      }
  in
  let options = Provider.{ max_tokens; temperature = None } in
  Printf.printf "model: %s\n" model_id;
  Printf.printf "prompt: %s\n" prompt_text;
  Printf.printf "---\n%!";
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let provider = Anthropic_provider.create ~env ~sw in
  let stream =
    Anthropic_provider.stream_simple provider ~model ~context ~options ~sw
  in
  let result =
    Event_stream.iter stream ~f:(fun event ->
        Printf.printf "%s\n%!" (describe_event event))
  in
  match result with
  | Ok final_msg ->
      Printf.printf "---\n";
      Printf.printf "done: stop_reason=%s content=[%s]\n"
        (stop_reason_string final_msg.Types.stop_reason)
        (summarise_content final_msg.Types.content);
      exit 0
  | Error msg ->
      Printf.printf "error: %s\n" msg;
      exit 1

let run_thinking_scenario () =
  let model = Types.{ id = "claude-sonnet-4-5"; api = "anthropic" } in
  let user_msg =
    Types.
      {
        role = "user";
        content =
          [ Types.UText "What is the 15th prime number? Show your reasoning." ];
      }
  in
  let context =
    Provider.
      {
        system = "You are a helpful assistant.";
        messages = [ Provider.UserMessage user_msg ];
        tools = [];
        thinking = true;
      }
  in
  let options = Provider.{ max_tokens = 16000; temperature = None } in
  Printf.printf "thinking scenario: model=%s\n%!" model.Types.id;
  Printf.printf "---\n%!";
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let provider = Anthropic_provider.create ~env ~sw in
  let stream =
    Anthropic_provider.stream_simple provider ~model ~context ~options ~sw
  in
  let events = ref [] in
  let result =
    Event_stream.iter stream ~f:(fun event ->
        events := event :: !events;
        Printf.printf "%s\n%!" (describe_event event))
  in
  match result with
  | Error msg ->
      Printf.printf "thinking scenario: FAIL: stream error: %s\n" msg;
      exit 1
  | Ok final_msg ->
      Printf.printf "---\n";
      Printf.printf "done: stop_reason=%s content=[%s]\n"
        (stop_reason_string final_msg.Types.stop_reason)
        (summarise_content final_msg.Types.content);
      let has_thinking_event =
        List.exists
          (function Types.AME_thinking_start _ -> true | _ -> false)
          !events
      in
      if has_thinking_event then (
        Printf.printf "thinking scenario: PASS\n";
        exit 0)
      else (
        Printf.printf "thinking scenario: FAIL: no AME_thinking_start events\n";
        exit 1)

let run_openai_completions_scenario () =
  match Sys.getenv_opt "OPENAI_API_KEY" with
  | None ->
      Printf.printf "openai-completions scenario: SKIP: OPENAI_API_KEY not set\n";
      exit 0
  | Some _ ->
      let user_msg =
        Types.{ role = "user"; content = [ Types.UText "Say hello in one word." ] }
      in
      let context =
        Provider.
          {
            system = "You are a helpful assistant.";
            messages = [ Provider.UserMessage user_msg ];
            tools = [];
            thinking = false;
          }
      in
      let options = Provider.{ max_tokens = 64; temperature = None } in
      Printf.printf "openai-completions scenario\n%!";
      Printf.printf "---\n%!";
      (try
         Eio_main.run @@ fun env ->
         Eio.Switch.run @@ fun sw ->
         let model_id = "gpt-4o-mini" in
         let model = Types.{ id = model_id; api = "openai-completions" } in
         let provider = Openai_completions_provider.create ~env ~sw in
         let stream =
           Openai_completions_provider.stream_simple provider ~model ~context
             ~options ~sw
         in
         let events = ref [] in
         let result =
           Event_stream.iter stream ~f:(fun event ->
               events := event :: !events;
               Printf.printf "%s\n%!" (describe_event event))
         in
         (match result with
         | Error msg ->
             Printf.printf "openai-completions scenario: FAIL: stream error: %s\n"
               msg;
             exit 1
         | Ok final_msg ->
             Printf.printf "---\n";
             Printf.printf "done: stop_reason=%s content=[%s]\n"
               (stop_reason_string final_msg.Types.stop_reason)
               (summarise_content final_msg.Types.content);
             let has_text_delta =
               List.exists
                 (function Types.AME_text_delta _ -> true | _ -> false)
                 !events
             in
             if has_text_delta then (
               Printf.printf "openai-completions scenario: PASS\n";
               exit 0)
             else (
               Printf.printf
                 "openai-completions scenario: FAIL: no AME_text_delta events\n";
               exit 1))
       with Failure msg ->
         Printf.printf "openai-completions scenario: FAIL: %s\n" msg;
         exit 1)

let () =
  Driver_log.setup ();
  let argv = Sys.argv in
  let argv1 = if Array.length argv > 1 then Some argv.(1) else None in
  match argv1 with
  | Some "thinking" -> (
      match Sys.getenv_opt "ANTHROPIC_API_KEY" with
      | None ->
          print_endline "skipped: no API key";
          exit 0
      | Some _ -> run_thinking_scenario ())
  | Some "openai-completions" -> run_openai_completions_scenario ()
  | _ -> (
      match Sys.getenv_opt "ANTHROPIC_API_KEY" with
      | None ->
          print_endline "skipped: no API key";
          exit 0
      | Some _ ->
          let default_model = "claude-3-5-haiku-latest" in
          let default_prompt = "What is the weather like in Sydney right now?" in
          let default_max_tokens = 4096 in
          let model_id = Option.value argv1 ~default:default_model in
          let prompt_text =
            if Array.length argv > 2 then argv.(2) else default_prompt
          in
          let max_tokens =
            if Array.length argv > 3 then
              match int_of_string_opt argv.(3) with
              | Some n -> n
              | None ->
                  Log.warn (fun m ->
                      m "invalid max_tokens %S, using %d" argv.(3)
                        default_max_tokens);
                  default_max_tokens
            else default_max_tokens
          in
          run_default_scenario ~model_id ~prompt_text ~max_tokens)
