(** Compaction driver — exercises [Compaction.compact] in isolation.

    Two scenarios: {b offline_faux} (always runs, uses [Faux_provider]) and
    {b real_model} (skips when [ANTHROPIC_API_KEY] is absent, calls the live
    Anthropic API and prints the produced summary for human inspection).

    Exit code: 0 if all non-skipped scenarios pass, 1 otherwise. *)

open Containers
open Pera_types
open Pera_connector
open Pera_core
open Pera_core_test_util
open Session_jsonl_helpers

(* ── Shared fixtures ──────────────────────────────────────────────────────── *)

let haiku_model : Types.model =
  {
    id = "claude-haiku-4-5-20251001";
    protocol = "anthropic";
    context_window = 200_000;
  }

let faux_provenance : Types.provenance =
  { protocol = "faux"; provider = "faux"; model = "faux"; error_message = None }

let faux_usage : Types.usage =
  {
    input_tokens = 0;
    output_tokens = 0;
    cache_read_tokens = 0;
    cache_write_tokens = 0;
    cost_usd = None;
  }

(* ── Conversation builder ─────────────────────────────────────────────────── *)

let make_user text =
  Agent_types.Real
    (Connector.UserMessage Types.{ role = "user"; content = [ UText text ] })

let make_assistant_text text =
  Agent_types.Real
    (Connector.AssistantMessage
       Types.
         {
           content = [ AText text ];
           stop_reason = EndTurn;
           provenance = faux_provenance;
           usage = faux_usage;
         })

let make_tool_call id name =
  Agent_types.Real
    (Connector.AssistantMessage
       Types.
         {
           content = [ AToolCall { id; name; arguments = `Assoc [] } ];
           stop_reason = ToolUse;
           provenance = faux_provenance;
           usage = faux_usage;
         })

let make_tool_result tool_call_id text =
  Agent_types.Real
    (Connector.ToolResultMessage
       Types.{ tool_call_id; content = `String text; is_error = false })

let build_conversation () =
  [
    make_user "Write a function to sort a list in ascending order.";
    make_tool_call "tc1" "bash";
    make_tool_result "tc1" "src/sort.ml\nsrc/main.ml";
    make_tool_call "tc2" "read";
    make_tool_result "tc2" "let sort lst = List.sort compare lst";
    make_tool_call "tc3" "write";
    make_tool_result "tc3" "Written successfully";
    make_assistant_text
      "Done. I have implemented the sort function in src/sort.ml.";
  ]

(* ── Faux stream script ───────────────────────────────────────────────────── *)

let offline_summary_text = "OFFLINE SUMMARY"

let make_summary_script () =
  let msg =
    Types.
      {
        content = [ AText offline_summary_text ];
        stop_reason = EndTurn;
        provenance = faux_provenance;
        usage = faux_usage;
      }
  in
  Faux_provider.Turn
    Faux_provider.
      { events = [ Types.AME_text_start { partial = msg } ]; final = msg }

(* ── Assertion helpers ────────────────────────────────────────────────────── *)

let starts_with_framing text =
  Int.equal (String.find ~sub:Agent_types.compaction_framing text) 0

let verify_offline_result ~original_messages ~tail_size r =
  let { Pera_harness.Compaction.new_messages; summary } = r in
  let expected_len = 1 + 1 + tail_size in
  if not (Int.equal (List.length new_messages) expected_len) then
    Fail
      (Printf.sprintf "new_messages length=%d, expected %d"
         (List.length new_messages) expected_len)
  else if not (String.equal summary offline_summary_text) then
    Fail
      (Printf.sprintf "summary='%s', expected '%s'" summary offline_summary_text)
  else
    let n = List.length original_messages in
    let orig_tail = List.drop (n - tail_size) original_messages in
    match (original_messages, new_messages) with
    | orig_first :: _, first_msg :: synth_msg :: rest_tail ->
        let rendered_synth = Agent_types.to_provider_message synth_msg in
        let synth_ok =
          match rendered_synth with
          | Connector.UserMessage { content = [ Types.UText text ]; _ } ->
              starts_with_framing text
          | _ -> false
        in
        if not (Agent_types.agent_message_equal first_msg orig_first) then
          Fail "first message in new_messages does not match original first"
        else if not synth_ok then
          Fail
            "element at index 1 is not a user message starting with \
             compaction_framing"
        else if
          not (List.equal Agent_types.agent_message_equal rest_tail orig_tail)
        then
          Fail
            "tail messages in new_messages do not match original last \
             tail_size messages"
        else Pass
    | [], _ ->
        failwith "build_conversation must return a non-empty message list"
    | _ :: _, _ ->
        (* impossible: length already verified above *)
        assert false

(* ── Scenarios ────────────────────────────────────────────────────────────── *)

let scenario_offline_faux ~env:_ =
  let tail_size = 3 in
  let messages = build_conversation () in
  let stream_fn =
    Faux_provider.stream_fn_of_scripts [ make_summary_script () ]
  in
  let options =
    Connector.
      {
        max_tokens = 1024;
        temperature = None;
        cache_policy = Pera_types.Types.No_cache;
        cache_ttl = Pera_types.Types.Five_minutes;
        thinking_budget_tokens = None;
      }
  in
  let result =
    Eio.Switch.run @@ fun sw ->
    Pera_harness.Compaction.compact ~stream_fn ~model:haiku_model ~options
      ~messages ~tail_size ~sw
  in
  match result with
  | Error msg -> Fail (Printf.sprintf "compact returned error: %s" msg)
  | Ok None ->
      Fail "compact returned None (nothing to compact) — expected Ok (Some r)"
  | Ok (Some r) ->
      verify_offline_result ~original_messages:messages ~tail_size r

let scenario_real_model ~env =
  let tail_size = 3 in
  let messages = build_conversation () in
  let model = haiku_model in
  let options =
    Connector.
      {
        max_tokens = 1024;
        temperature = None;
        cache_policy = Pera_types.Types.No_cache;
        cache_ttl = Pera_types.Types.Five_minutes;
        thinking_budget_tokens = None;
      }
  in
  let registry =
    Connector_registry.register Connector_registry.empty ~name:"anthropic"
      (module Anthropic_connector)
  in
  let api_keys =
    [ ("anthropic",
       Option.get_exn_or "ANTHROPIC_API_KEY" (Sys.getenv_opt "ANTHROPIC_API_KEY"))
    ]
  in
  let result =
    Eio.Switch.run @@ fun sw ->
    let adapter =
      Connector_adapter.create ~registry ~api_keys ~base_url:"https://api.anthropic.com" ~env ~sw
    in
    let stream_fn = Connector_adapter.stream_fn adapter in
    Pera_harness.Compaction.compact ~stream_fn ~model ~options ~messages
      ~tail_size ~sw
  in
  match result with
  | Error msg -> Fail (Printf.sprintf "compact returned error: %s" msg)
  | Ok None ->
      Fail "compact returned None (nothing to compact) — expected Ok (Some r)"
  | Ok (Some { Pera_harness.Compaction.summary; _ }) ->
      if String.equal summary "" then Fail "real model produced empty summary"
      else begin
        Printf.printf "  [summary] %s\n%!" (String.take 200 summary);
        Pass
      end

(* ── Main ─────────────────────────────────────────────────────────────────── *)

let () =
  let exit_code =
    Eio_main.run @@ fun env ->
    let result =
      try
        let offline_verdict = scenario_offline_faux ~env in
        print_verdict ~tag:"compaction" ~scenario:"offline_faux" offline_verdict;
        let real_verdict_opt =
          match Sys.getenv_opt "ANTHROPIC_API_KEY" with
          | None ->
              Printf.printf
                "[compaction] real_model ... SKIP: no ANTHROPIC_API_KEY\n%!";
              None
          | Some _ ->
              let v = scenario_real_model ~env in
              print_verdict ~tag:"compaction" ~scenario:"real_model" v;
              Some v
        in
        Printf.printf "\n";
        let all_verdicts =
          match real_verdict_opt with
          | None -> [ offline_verdict ]
          | Some v -> [ offline_verdict; v ]
        in
        let passed =
          List.length
            (List.filter
               (function Pass -> true | Fail _ -> false)
               all_verdicts)
        in
        let total = List.length all_verdicts in
        Printf.printf "%d/%d scenarios passed.\n" passed total;
        if passed = total then 0 else 1
      with
      | Failure msg ->
          Printf.eprintf "compaction_driver: %s\n%!" msg;
          2
      | exn ->
          Printf.eprintf "compaction_driver crashed: %s\n%!"
            (Printexc.to_string exn);
          1
    in
    result
  in
  exit exit_code
