open Containers
open Pera_core
open Pera_core_test_util

(** {1 Message builders} *)

(** [make_assistant_message ?stop_reason content] builds a minimal
    [assistant_message] with the given content blocks and stop_reason. The
    provenance and usage fields are filled with faux sentinel values. *)
let make_assistant_message ?(stop_reason = Pera_types.Types.EndTurn) content =
  Pera_types.Types.
    {
      content;
      stop_reason;
      provenance =
        {
          protocol = "faux";
          provider = "faux";
          model = "faux";
          error_message = None;
        };
      usage =
        {
          input_tokens = 0;
          output_tokens = 0;
          cache_read_tokens = 0;
          cache_write_tokens = 0;
          cost_usd = None;
        };
    }

(** [make_text_assistant_message text] builds an [assistant_message] with a
    single [AText] block and [EndTurn] stop_reason. *)
let make_text_assistant_message text =
  make_assistant_message [ Pera_types.Types.AText text ]

(** [make_tool_use_assistant_message tool_calls] builds an [assistant_message]
    wrapping the given tool calls with [ToolUse] stop_reason. *)
let make_tool_use_assistant_message tool_calls =
  let content = List.map (fun tc -> Pera_types.Types.AToolCall tc) tool_calls in
  make_assistant_message ~stop_reason:Pera_types.Types.ToolUse content

(** [make_tool_call id name arguments] builds a [tool_call] record. *)
let make_tool_call id name arguments = Pera_types.Types.{ id; name; arguments }

(** [make_user_agent_message text] builds an [agent_message] wrapping a
    [UserMessage] with a single [UText] block. *)
let make_user_agent_message text =
  let um = Pera_types.Types.{ role = "user"; content = [ UText text ] } in
  Agent_types.Real (Pera_connector.Connector.UserMessage um)

(** {1 Config defaults} *)

(** [default_convert_to_llm msgs] converts agent messages to provider messages
    using the shared [Agent_types.to_provider_message] projection. *)
let default_convert_to_llm msgs = List.map Agent_types.to_provider_message msgs

(** A model value for loop calls. *)
let test_model =
  Pera_types.Types.{ id = "test-model"; protocol = "faux"; context_window = 200_000 }

(** Simple stream options for loop calls. *)
let test_options =
  Pera_connector.Connector.
    {
      max_tokens = 1024;
      temperature = None;
      cache_policy = Pera_types.Types.No_cache;
      cache_ttl = Pera_types.Types.Five_minutes;
      thinking_budget_tokens = None;
    }

(** {1 Script builders} *)

(** [make_text_turn_script text] builds a [Faux_provider] script for a text-only
    turn that emits [AME_text_start] and [AME_text_delta] events before
    resolving with a final message containing [text]. *)
let make_text_turn_script text =
  let partial_msg = make_text_assistant_message "" in
  let final_msg = make_text_assistant_message text in
  Faux_provider.Turn
    Faux_provider.
      {
        events =
          [
            Pera_types.Types.AME_text_start { partial = partial_msg };
            Pera_types.Types.AME_text_delta { text; partial = final_msg };
          ];
        final = final_msg;
      }

(** [make_tool_use_turn_script tool_calls] builds a [Faux_provider] script for a
    turn that issues the given tool calls. Raises if [tool_calls] is empty. *)
let make_tool_use_turn_script tool_calls =
  let final_msg = make_tool_use_assistant_message tool_calls in
  let first_tc =
    List.nth_opt tool_calls 0
    |> Option.get_exn_or
         "make_tool_use_turn_script: tool_calls must be non-empty"
  in
  Faux_provider.Turn
    Faux_provider.
      {
        events =
          [
            Pera_types.Types.AME_tool_call_start
              {
                index = 0;
                id = first_tc.Pera_types.Types.id;
                name = first_tc.Pera_types.Types.name;
                partial = make_tool_use_assistant_message tool_calls;
              };
          ];
        final = final_msg;
      }

(** {1 Schema values} *)

(** A tool schema with no properties and no required fields. *)
let empty_schema =
  Pera_connector.Json_schema.object_ ~properties:[] ~required:[] ()

(** A tool schema requiring a field named ["x"] of type integer. *)
let int_field_schema =
  Pera_connector.Json_schema.object_
    ~properties:[ ("x", Pera_connector.Json_schema.integer ()) ]
    ~required:[ "x" ] ()

(** {1 Event stream helpers} *)

(** [collect_agent_events stream] drains an [Event_stream] of [agent_event]
    values into a list and returns [(events, result)]. *)
let collect_agent_events stream =
  let buf = ref [] in
  let result =
    Pera_connector.Event_stream.iter stream ~f:(fun e -> buf := e :: !buf)
  in
  (List.rev !buf, result)

(** [count_events pred events] returns the number of events satisfying [pred].
*)
let count_events pred events = List.length (List.filter pred events)

(** {1 Ordering assertions} *)

(** [find_first_index pred events] returns the index of the first element
    satisfying [pred], or [None] if no element does. *)
let find_first_index pred events =
  let indexed = List.mapi (fun i e -> (i, e)) events in
  List.find_opt (fun (_, e) -> pred e) indexed |> Option.map fst

(** [check_before ~message ~before ~events label] asserts that the first index
    in [events] matching [message] is strictly less than the first index
    matching [before]. Calls [Alcotest.fail] with a descriptive message if the
    assertion does not hold. *)
let check_before ~message ~before ~events label =
  let message_idx = find_first_index message events in
  let before_idx = find_first_index before events in
  match (message_idx, before_idx) with
  | None, _ ->
      Alcotest.failf "%s: check_before: 'message' predicate matched no event"
        label
  | _, None ->
      Alcotest.failf "%s: check_before: 'before' predicate matched no event"
        label
  | Some mi, Some bi ->
      if mi >= bi then
        Alcotest.failf
          "%s: check_before failed — 'message' index %d is not < 'before' \
           index %d"
          label mi bi

(** [check_event_order labeled_preds events] asserts that the events matching
    each predicate in [labeled_preds] appear in the given order. Each element is
    [(label, predicate)]. Calls [Alcotest.fail] on the first out-of-order pair.
*)
let check_event_order labeled_preds events =
  let indices =
    List.map
      (fun (label, pred) ->
        match find_first_index pred events with
        | None ->
            Alcotest.failf "check_event_order: no event matched '%s'" label
        | Some i -> (label, i))
      labeled_preds
  in
  let rec check_pairs = function
    | [] | [ _ ] -> ()
    | (l1, i1) :: ((l2, i2) :: _ as rest) ->
        if i1 >= i2 then
          Alcotest.failf
            "check_event_order: '%s' (index %d) is not before '%s' (index %d)"
            l1 i1 l2 i2
        else check_pairs rest
  in
  check_pairs indices
