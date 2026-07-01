(** Live driver — exercises the full Agent_harness stack against the real
    Anthropic API with real filesystem tools and session logging.

    Requires ANTHROPIC_API_KEY. Skipped if absent.

    Three scenarios (each tests a distinct tool and property): 1. bash_echo —
    bash tool; stdout captured in session tool result. 2. read_preseeded — read
    tool; we write the file before the harness runs so the sentinel is fully
    deterministic and no write tool is involved. 3. multi_turn — two sequential
    sends; send 1 writes a file, send 2 reads it back; sentinel in the read tool
    result proves the model used the tool rather than recalling context.

    Exit code: 0 if all pass, 1 otherwise. *)

open Containers
open Pera_types
open Pera_connector
open Pera_core
open Session_jsonl_helpers

(* ── Model ────────────────────────────────────────────────────────────────── *)

let default_model : Types.model =
  {
    id = "claude-haiku-4-5-20251001";
    protocol = "anthropic";
    context_window = 200_000;
  }

let model_of_argv () =
  if Array.length Sys.argv > 1 then
    (* TODO: accept --context-window from the CLI; 200K is wrong for 1M Claude
       variants and for non-Anthropic models passed via this driver. *)
    Types.{ id = Sys.argv.(1); protocol = "anthropic"; context_window = 200_000 }
  else default_model

(* ── Session content helpers ──────────────────────────────────────────────── *)

let text_blocks_of_content content_json =
  let blocks = Yojson.Safe.Util.to_list content_json in
  List.filter_map
    (fun block ->
      match get_string_opt "type" block with
      | Some "text" -> get_string_opt "text" block
      | _ -> None)
    blocks

(** All text strings from assistant message entries in the session. *)
let collect_assistant_texts entries =
  List.concat_map
    (fun e ->
      if not (String.equal (get_string "type" e) "message") then []
      else
        let msg = Yojson.Safe.Util.member "message" e in
        match get_string_opt "role" msg with
        | Some "assistant" ->
            text_blocks_of_content (Yojson.Safe.Util.member "content" msg)
        | _ -> [])
    entries

(** All tool-result content strings from tool_result entries in the session. *)
let collect_tool_result_strings entries =
  List.filter_map
    (fun e ->
      if not (String.equal (get_string "type" e) "message") then None
      else
        let msg = Yojson.Safe.Util.member "message" e in
        match get_string_opt "role" msg with
        | Some "tool_result" -> (
            let content = Yojson.Safe.Util.member "content" msg in
            match content with
            | `String s -> Some s
            | other -> Some (Yojson.Safe.to_string other))
        | _ -> None)
    entries

let has_tool_results entries =
  not (List.is_empty (collect_tool_result_strings entries))

let contains_sub ~needle s = String.find ~sub:needle s >= 0

(** True if [needle] appears in any assistant text or tool result in [entries].
*)
let session_output_contains ~needle entries =
  List.exists (contains_sub ~needle) (collect_assistant_texts entries)
  || List.exists (contains_sub ~needle) (collect_tool_result_strings entries)

(* ── Harness config helper ────────────────────────────────────────────────── *)

let make_harness_config ~model ~tmpdir ~session_path ~stream_fn ~exec_env :
    Pera_agent.Agent_harness.config =
  {
    cwd = tmpdir;
    model;
    session_path;
    stream_fn;
    max_tokens = 1024;
    exec_env;
    system_prompt = Pera_agent.Agent_harness.default_system_prompt;
    thinking_budget_tokens = None;
    cache_policy = Pera_types.Types.No_cache;
    cache_ttl = Pera_types.Types.Five_minutes;
    extra_tools = [];
    compaction = None;
  }

let zero_usage : Types.usage =
  Types.
    {
      input_tokens = 0;
      output_tokens = 0;
      cache_read_tokens = 0;
      cache_write_tokens = 0;
      cost_usd = None;
    }

(* ── Verify helpers ───────────────────────────────────────────────────────── *)

let verify_bash_echo sentinel entries =
  if not (has_tool_results entries) then
    Fail "no tool_result entries in session"
  else if not (session_output_contains ~needle:sentinel entries) then
    Fail
      (Printf.sprintf
         "sentinel '%s' not found in tool output or assistant response" sentinel)
  else verify_chain_and_leaves entries

let verify_read_preseeded ~sentinel entries =
  if not (has_tool_results entries) then
    Fail "no tool_result entries in session"
  else if not (session_output_contains ~needle:sentinel entries) then
    Fail
      (Printf.sprintf
         "sentinel '%s' not found in tool result or assistant response" sentinel)
  else verify_chain_and_leaves entries

let verify_multi_turn ~sentinel entries =
  (* The read tool result from send 2 must contain the sentinel — this can only
     come from the file on disk, not from context recall. *)
  let tool_results = collect_tool_result_strings entries in
  let read_result_has_sentinel =
    List.exists (contains_sub ~needle:sentinel) tool_results
  in
  if not read_result_has_sentinel then
    Fail
      (Printf.sprintf
         "sentinel '%s' not found in any tool result — read tool did not \
          execute or returned wrong content"
         sentinel)
  else
    match List.last_opt (collect_assistant_texts entries) with
    | None -> Fail "no assistant text found after send 2"
    | Some last ->
        if not (contains_sub ~needle:sentinel last) then
          Fail
            (Printf.sprintf
               "send-2 response does not contain sentinel '%s'; got: '%s'"
               sentinel (String.take 100 last))
        else verify_chain_and_leaves entries

(* ── Provider setup ───────────────────────────────────────────────────────── *)

let build_anthropic_registry () =
  Connector_registry.register Connector_registry.empty ~name:"anthropic"
    (module Anthropic_connector)

(** The per-connector API-key list for the Anthropic-only registry built by
    {!build_anthropic_registry}. *)
let anthropic_api_keys () =
  [ ("anthropic",
     Option.get_exn_or "ANTHROPIC_API_KEY" (Sys.getenv_opt "ANTHROPIC_API_KEY"))
  ]

(* ── Scenarios ────────────────────────────────────────────────────────────── *)

(** Format a [stop_error] as a short category label for the outer message. *)
let format_stop_error = function
  | Pera_types.Types.Transport -> "transport"
  | Pera_types.Types.Http { status } -> Printf.sprintf "HTTP %d" status
  | Pera_types.Types.Provider { message } ->
      Printf.sprintf "provider: %s" message
  | Pera_types.Types.Internal { message } ->
      Printf.sprintf "internal: %s" message

(** Check the harness for an infrastructure or internal error after [send].
    Returns [Some fail] if an error occurred, [None] if the run completed
    without errors. *)
let check_harness_error h =
  match Pera_agent.Agent_harness.last_error h with
  | None -> None
  | Some (msg, stop_err) ->
      Some
        (Fail
           (Printf.sprintf "infrastructure error (%s): %s"
              (format_stop_error stop_err)
              msg))

(** If the harness has no error, run [f]; otherwise return the error failure
    with zero usage. *)
let if_no_error h f =
  match check_harness_error h with
  | Some fail -> (fail, zero_usage)
  | None -> f ()

let scenario_bash_echo ~model ~tmpdir ~env ~registry =
  Eio.Switch.run @@ fun sw ->
  let session_path = Filename.concat tmpdir "bash_echo.jsonl" in
  let sentinel = "pera_echo_42" in
  let adapter =
    Connector_adapter.create ~registry
      ~api_keys:(anthropic_api_keys ())
      ~base_url:"https://api.anthropic.com"
      ~env ~sw
  in
  let stream_fn = Connector_adapter.stream_fn adapter in
  let exec_env = Pera_env.Local_env.create ~env ~cwd:tmpdir in
  let config =
    make_harness_config ~model ~tmpdir ~session_path ~stream_fn ~exec_env
  in
  match Pera_agent.Agent_harness.create ~config ~env ~sw with
  | Error e ->
      (Fail (Printf.sprintf "create failed: %s" e.Types.message), zero_usage)
  | Ok h ->
      Pera_agent.Agent_harness.send h
        (Printf.sprintf
           "Use the bash tool to run the command `echo %s` and report the \
            exact output."
           sentinel);
      if_no_error h (fun () ->
          let entries = parse_session_file session_path in
          (verify_bash_echo sentinel entries, collect_cumulative_usage entries))

let scenario_read_preseeded ~model ~tmpdir ~env ~registry =
  (* Write the sentinel ourselves before the harness runs — the model's only
     job is to call the read tool and report the contents. *)
  let seed_file = Filename.concat tmpdir "preseeded.txt" in
  let sentinel = "pera_sentinel_xyz" in
  Stdlib.Out_channel.(
    with_open_text seed_file (fun oc -> output_string oc sentinel));
  Eio.Switch.run @@ fun sw ->
  let session_path = Filename.concat tmpdir "read_preseeded.jsonl" in
  let adapter =
    Connector_adapter.create ~registry
      ~api_keys:(anthropic_api_keys ())
      ~base_url:"https://api.anthropic.com"
      ~env ~sw
  in
  let stream_fn = Connector_adapter.stream_fn adapter in
  let exec_env = Pera_env.Local_env.create ~env ~cwd:tmpdir in
  let config =
    make_harness_config ~model ~tmpdir ~session_path ~stream_fn ~exec_env
  in
  match Pera_agent.Agent_harness.create ~config ~env ~sw with
  | Error e ->
      (Fail (Printf.sprintf "create failed: %s" e.Types.message), zero_usage)
  | Ok h ->
      Pera_agent.Agent_harness.send h
        (Printf.sprintf "Use the read tool to read %s and tell me its contents."
           seed_file);
      if_no_error h (fun () ->
          let entries = parse_session_file session_path in
          ( verify_read_preseeded ~sentinel entries,
            collect_cumulative_usage entries ))

let scenario_multi_turn ~model ~tmpdir ~env ~registry =
  (* Send 1: write a sentinel to disk. Send 2: use the read tool to read it
     back and reproduce the value. The sentinel in the send-2 tool result can
     only come from the file — the model cannot fabricate it from context
     without actually calling the read tool. *)
  Eio.Switch.run @@ fun sw ->
  let session_path = Filename.concat tmpdir "multi_turn.jsonl" in
  let data_file = Filename.concat tmpdir "mt_data.txt" in
  let sentinel = "pera_token_789" in
  let adapter =
    Connector_adapter.create ~registry
      ~api_keys:(anthropic_api_keys ())
      ~base_url:"https://api.anthropic.com"
      ~env ~sw
  in
  let stream_fn = Connector_adapter.stream_fn adapter in
  let exec_env = Pera_env.Local_env.create ~env ~cwd:tmpdir in
  let config =
    make_harness_config ~model ~tmpdir ~session_path ~stream_fn ~exec_env
  in
  match Pera_agent.Agent_harness.create ~config ~env ~sw with
  | Error e ->
      (Fail (Printf.sprintf "create failed: %s" e.Types.message), zero_usage)
  | Ok h ->
      Pera_agent.Agent_harness.send h
        (Printf.sprintf
           "Use the write tool to write exactly `%s` to the file %s." sentinel
           data_file);
      if_no_error h (fun () ->
          Pera_agent.Agent_harness.send h
            (Printf.sprintf
               "Use the read tool to read the file %s and tell me exactly what \
                it contains."
               data_file);
          if_no_error h (fun () ->
              let entries = parse_session_file session_path in
              ( verify_multi_turn ~sentinel entries,
                collect_cumulative_usage entries )))

(* ── Main ─────────────────────────────────────────────────────────────────── *)

let () =
  match Sys.getenv_opt "ANTHROPIC_API_KEY" with
  | None ->
      print_endline "[live] skipped: ANTHROPIC_API_KEY not set";
      exit 0
  | Some _ ->
      let exit_code =
        Eio_main.run @@ fun env ->
        let tmpdir = make_temp_dir env ~prefix:"pera_live_driver" in
        let result =
          try
            let model = model_of_argv () in
            let registry = build_anthropic_registry () in
            Printf.printf "model: %s\n%!" model.Types.id;
            let scenarios =
              [
                ("bash_echo", scenario_bash_echo ~model ~tmpdir ~env ~registry);
                ( "read_preseeded",
                  scenario_read_preseeded ~model ~tmpdir ~env ~registry );
                ("multi_turn", scenario_multi_turn ~model ~tmpdir ~env ~registry);
              ]
            in
            List.iter
              (fun (name, (v, usage)) ->
                print_verdict ~tag:"live" ~scenario:name v;
                Printf.printf "  usage: %s\n" (Usage_status.format usage))
              scenarios;
            Printf.printf "\n";
            let passed =
              count_passed
                (List.map (fun (name, (v, _)) -> (name, v)) scenarios)
            in
            let total = List.length scenarios in
            Printf.printf "%d/%d scenarios passed.\n" passed total;
            if passed = total then 0 else 1
          with
          | Failure msg ->
              Printf.eprintf "live_driver: %s\n%!" msg;
              2
          | exn ->
              Printf.eprintf "live_driver crashed: %s\n%!"
                (Printexc.to_string exn);
              1
        in
        cleanup tmpdir;
        result
      in
      exit exit_code
