open Containers
open Pera_core
open Pera_provider

type compaction_result = {
  new_messages : Agent_types.agent_message list;
  summary : string;
}

let summarise_prompt =
  "You are compacting a long coding-assistant conversation to fit a context \
   window.\n\
   Produce a concise summary that PRESERVES:\n\
   - the original task / goal;\n\
   - every file path the agent has created or edited, each with a one-line \
   note of what changed;\n\
   - outstanding decisions, open questions, and the current plan;\n\
   - the working understanding of the project (key facts, constraints).\n\
   DISCARD:\n\
   - file contents (they can be re-read);\n\
   - exploration that led nowhere;\n\
   - tool calls whose results were superseded by later work.\n\
   Output structured prose with short section headers. Do not address the \
   user; write the summary as notes."

let render_message buf msg =
  match msg with
  | Provider.UserMessage Pera_types.Types.{ content; _ } ->
      Buffer.add_string buf "User:\n";
      List.iter
        (fun block ->
          match block with
          | Pera_types.Types.UText text -> Buffer.add_string buf text
          | Pera_types.Types.UImage { url; _ } ->
              Buffer.add_string buf ("[image: " ^ url ^ "]"))
        content;
      Buffer.add_char buf '\n'
  | Provider.AssistantMessage Pera_types.Types.{ content; _ } ->
      Buffer.add_string buf "Assistant:\n";
      List.iter
        (fun block ->
          match block with
          | Pera_types.Types.AText text -> Buffer.add_string buf text
          | Pera_types.Types.AThinking { text; _ } -> Buffer.add_string buf text
          | Pera_types.Types.AToolCall
              Pera_types.Types.{ id = _; name; arguments } ->
              Buffer.add_string buf
                ("[tool_call name=" ^ name ^ " args="
                ^ Yojson.Safe.to_string arguments
                ^ "]"))
        content;
      Buffer.add_char buf '\n'
  | Provider.ToolResultMessage Pera_types.Types.{ tool_call_id; content; _ } ->
      Buffer.add_string buf
        ("Tool result (id=" ^ tool_call_id ^ "): "
        ^ Yojson.Safe.to_string content);
      Buffer.add_char buf '\n'

let render_messages_to_text messages =
  let buf = Buffer.create 512 in
  List.iter (render_message buf) messages;
  Buffer.contents buf

let collect_summary_text final =
  List.filter_map
    (fun block ->
      match block with
      | Pera_types.Types.AText text -> Some text
      | Pera_types.Types.AThinking _ | Pera_types.Types.AToolCall _ -> None)
    final.Pera_types.Types.content
  |> String.concat ""

let compact ~stream_fn ~model ~options ~messages ~tail_size ~sw =
  let n = List.length messages in
  if n <= tail_size + 1 then Ok None
  else
    let open Result.Syntax in
    let first, rest =
      match messages with
      | [] ->
          (* Impossible: n > tail_size + 1 >= 2 *)
          failwith "Compaction.compact: invariant violated — messages is empty"
      | hd :: tl -> (hd, tl)
    in
    let middle_count = n - 1 - tail_size in
    let middle = List.take middle_count rest in
    let tail = List.drop middle_count rest in
    let rendered =
      render_messages_to_text (List.map Agent_types.to_provider_message middle)
    in
    let user_msg =
      Provider.UserMessage
        Pera_types.Types.
          {
            role = "user";
            content = [ UText ("Conversation to summarise:\n\n" ^ rendered) ];
          }
    in
    let context =
      Provider.
        {
          system = summarise_prompt;
          messages = [ user_msg ];
          tools = [];
          thinking = false;
        }
    in
    let stream = stream_fn ~model ~context ~options ~sw in
    let* final =
      Event_stream.iter stream ~f:(fun _ -> ()) |> Result.map_err fst
    in
    let summary = collect_summary_text final in
    if String.equal summary "" then Error "compaction produced empty summary"
    else
      let synthetic =
        Agent_types.Synthetic (Agent_types.Compaction_summary { summary })
      in
      let new_messages = [ first ] @ [ synthetic ] @ tail in
      Ok (Some { new_messages; summary })
