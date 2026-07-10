(** Compaction driver — exercises [Compaction.compact] against the real
    Anthropic API and prints the produced summary for human inspection.

    Requires [ANTHROPIC_API_KEY]. Skipped if absent.

    Exit code: 0 if the scenario passes, 1 otherwise. *)

open Containers
open Pera_types
open Pera_connector
open Pera_core
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

(* ── Scenarios ────────────────────────────────────────────────────────────── *)

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
    [
      ( "anthropic",
        Option.get_exn_or "ANTHROPIC_API_KEY"
          (Sys.getenv_opt "ANTHROPIC_API_KEY") );
    ]
  in
  let result =
    Eio.Switch.run @@ fun sw ->
    let adapter =
      Connector_adapter.create ~registry ~api_keys
        ~base_url:"https://api.anthropic.com" ~env ~sw
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
        match Sys.getenv_opt "ANTHROPIC_API_KEY" with
        | None ->
            Printf.printf
              "[compaction] real_model ... SKIP: no ANTHROPIC_API_KEY\n%!";
            0
        | Some _ -> (
            let v = scenario_real_model ~env in
            print_verdict ~tag:"compaction" ~scenario:"real_model" v;
            Printf.printf "\n";
            match v with Pass -> 0 | Fail _ -> 1)
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
