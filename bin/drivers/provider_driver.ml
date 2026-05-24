open Containers
open Pera_provider
open Pera_types

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
  | Types.AME_tool_call_end { index; _ } ->
      Printf.sprintf "[tool_call_end] index=%d" index
  | Types.AME_done _ -> "[done]"
  | Types.AME_error { message; _ } ->
      Printf.sprintf "[error] %s" (truncate 80 message)

(** Format the content of an assistant message for the summary line. *)
let summarise_content content =
  let format_block = function
    | Types.AText text -> Printf.sprintf "text(%d chars)" (String.length text)
    | Types.AThinking { text; _ } ->
        Printf.sprintf "thinking(%d chars)" (String.length text)
    | Types.AToolCall { name; _ } -> Printf.sprintf "tool_call(%s)" name
  in
  let blocks = List.map format_block content in
  if List.is_empty blocks then "(empty)" else String.concat ", " blocks

let () =
  match Sys.getenv_opt "ANTHROPIC_API_KEY" with
  | None ->
      print_endline "skipped: no API key";
      exit 0
  | Some _ -> (
      let argv = Sys.argv in
      let default_model = "claude-3-5-haiku-latest" in
      let default_prompt = "Say hello in one word" in
      let model_id =
        if Array.length argv > 1 then argv.(1) else default_model
      in
      let prompt_text =
        if Array.length argv > 2 then argv.(2) else default_prompt
      in
      let model = Types.{ id = model_id; api = "anthropic" } in
      let user_msg =
        Types.{ role = "user"; content = [ Types.UText prompt_text ] }
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
      let options = Provider.{ max_tokens = 256; temperature = None } in
      Printf.printf "model: %s\n" model_id;
      Printf.printf "prompt: %s\n" prompt_text;
      Printf.printf "---\n%!";
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let stream =
        Anthropic_provider.stream_simple ~env ~model ~context ~options ~sw
      in
      let result =
        Event_stream.iter stream ~f:(fun event ->
            let description = describe_event event in
            Printf.printf "%s\n%!" description)
      in
      match result with
      | Ok final_msg ->
          Printf.printf "---\n";
          Printf.printf "done: stop_reason=%s content=[%s]\n"
            (match final_msg.Types.stop_reason with
            | Types.EndTurn -> "end_turn"
            | Types.ToolUse -> "tool_use"
            | Types.MaxTokens -> "max_tokens"
            | Types.StopSequence -> "stop_sequence"
            | Types.Error -> "error"
            | Types.Aborted -> "aborted")
            (summarise_content final_msg.Types.content);
          exit 0
      | Error msg ->
          Printf.printf "error: %s\n" msg;
          exit 1)
