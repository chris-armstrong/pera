open Containers

type stats = {
  mutable turns : int;
  mutable input_tokens : int;
  mutable output_tokens : int;
  mutable cache_read : int;
  mutable cache_write : int;
  mutable model_name : string;
}

type t = {
  output : Pera_config.output_config;
  json : bool;
  stats : stats;
  mutable in_thinking : bool;
}

let create ~output ~json =
  let stats =
    {
      turns = 0;
      input_tokens = 0;
      output_tokens = 0;
      cache_read = 0;
      cache_write = 0;
      model_name = "";
    }
  in
  { output; json; stats; in_thinking = false }

let show_thinking r = Option.get_or ~default:false r.output.show_thinking
let is_quiet r = Option.get_or ~default:false r.output.quiet

let accumulate_usage r (usage : Pera_types.Types.usage) =
  r.stats.input_tokens <- r.stats.input_tokens + usage.input_tokens;
  r.stats.output_tokens <- r.stats.output_tokens + usage.output_tokens;
  r.stats.cache_read <- r.stats.cache_read + usage.cache_read_tokens;
  r.stats.cache_write <- r.stats.cache_write + usage.cache_write_tokens

let accumulate_from_message r (msg : Pera_core.Agent_types.agent_message) =
  match msg with
  | Real (Pera_connector.Connector.AssistantMessage am) ->
      accumulate_usage r am.Pera_types.Types.usage;
      r.stats.model_name <- am.Pera_types.Types.provenance.model
  | _ -> ()

let json_event event_type extra_fields =
  let fields = ("type", `String event_type) :: extra_fields in
  [ Yojson.Safe.to_string (`Assoc fields) ^ "\n" ]

let render r event =
  if r.json then
    match event with
    | Pera_core.Agent_types.AE_agent_start -> json_event "agent_start" []
    | Pera_core.Agent_types.AE_agent_end { messages = _ } ->
        json_event "agent_end" []
    | Pera_core.Agent_types.AE_turn_start -> json_event "turn_start" []
    | Pera_core.Agent_types.AE_turn_end { message = _; tool_results = _ } ->
        json_event "turn_end" []
    | Pera_core.Agent_types.AE_message_start { message = _ } ->
        json_event "message_start" []
    | Pera_core.Agent_types.AE_message_update { message = _; event = ev } -> (
        match ev with
        | Pera_types.Types.AME_text_delta { text; partial = _ } ->
            json_event "text_delta" [ ("text", `String text) ]
        | Pera_types.Types.AME_thinking_delta { text; partial = _ } ->
            json_event "thinking_delta" [ ("text", `String text) ]
        | _ -> [])
    | Pera_core.Agent_types.AE_message_end { message } ->
        accumulate_from_message r message;
        json_event "message_end" []
    | Pera_core.Agent_types.AE_tool_execution_start
        { tool_call_id = _; tool_name; args = _ } ->
        json_event "tool_start" [ ("tool", `String tool_name) ]
    | Pera_core.Agent_types.AE_tool_execution_end
        { tool_call_id = _; tool_name; result = _; is_error } ->
        json_event "tool_end"
          [ ("tool", `String tool_name); ("is_error", `Bool is_error) ]
    | Pera_core.Agent_types.AE_compaction_start ->
        json_event "compaction_start" []
    | Pera_core.Agent_types.AE_compaction_end { summary = _ } ->
        json_event "compaction_end" []
    | Pera_core.Agent_types.AE_compaction_error { message = _ } ->
        json_event "compaction_error" []
    | _ -> []
  else
    let quiet = is_quiet r in
    let show = show_thinking r in
    match event with
    | Pera_core.Agent_types.AE_message_update { message = _; event = ev } -> (
        match ev with
        | Pera_types.Types.AME_text_delta { text; partial = _ } ->
            r.in_thinking <- false;
            [ text ]
        | Pera_types.Types.AME_thinking_delta { text; partial = _ } ->
            if show then (
              r.in_thinking <- false;
              [ text ])
            else if not r.in_thinking then (
              r.in_thinking <- true;
              [ "\n[thinking...]\n" ])
            else []
        | _ -> [])
    | Pera_core.Agent_types.AE_turn_end _ ->
        r.stats.turns <- r.stats.turns + 1;
        r.in_thinking <- false;
        []
    | Pera_core.Agent_types.AE_message_end { message } ->
        accumulate_from_message r message;
        r.in_thinking <- false;
        []
    | Pera_core.Agent_types.AE_tool_execution_start { tool_name; _ } ->
        if quiet then [] else [ "\n[tool: " ^ tool_name ^ " — running...]" ]
    | Pera_core.Agent_types.AE_tool_execution_end { tool_name; is_error; _ } ->
        if quiet then []
        else if is_error then [ "\n[tool: " ^ tool_name ^ " — error]" ]
        else [ "[done]" ]
    | Pera_core.Agent_types.AE_agent_end _ -> [ "\n" ]
    | Pera_core.Agent_types.AE_compaction_start ->
        [ "\n[compacting context...]" ]
    | Pera_core.Agent_types.AE_compaction_end _ -> [ "[done]\n" ]
    | Pera_core.Agent_types.AE_compaction_error { message = _ } ->
        [ "\n[compaction failed]" ]
    | _ -> []

let stats r =
  let s = r.stats in
  Printf.sprintf
    "Model: %s | Turns: %d | In: %d Out: %d Cache-R: %d Cache-W: %d"
    s.model_name s.turns s.input_tokens s.output_tokens s.cache_read
    s.cache_write
