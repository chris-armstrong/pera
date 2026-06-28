open Containers

let default_output =
  Pera_cli.Pera_config.{ show_thinking = None; quiet = None }

let make_text_delta text =
  Pera_core.Agent_types.AE_message_update
    {
      message =
        Real
          (Pera_connector.Connector.AssistantMessage
             Pera_types.Types.
               {
                 content = [ AText "" ];
                 stop_reason = EndTurn;
                 provenance =
                   {
                     protocol = "test";
                     provider = "test";
                     model = "test";
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
               });
      event =
        Pera_types.Types.AME_text_delta
          {
            text;
            partial =
              Pera_types.Types.
                {
                  content = [ AText text ];
                  stop_reason = EndTurn;
                  provenance =
                    {
                      protocol = "test";
                      provider = "test";
                      model = "test";
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
                };
          };
    }

let make_thinking_delta text =
  Pera_core.Agent_types.AE_message_update
    {
      message =
        Real
          (Pera_connector.Connector.AssistantMessage
             Pera_types.Types.
               {
                 content = [ AThinking { text = ""; signature = None } ];
                 stop_reason = EndTurn;
                 provenance =
                   {
                     protocol = "test";
                     provider = "test";
                     model = "test";
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
               });
      event =
        Pera_types.Types.AME_thinking_delta
          {
            text;
            partial =
              Pera_types.Types.
                {
                  content = [ AThinking { text; signature = None } ];
                  stop_reason = EndTurn;
                  provenance =
                    {
                      protocol = "test";
                      provider = "test";
                      model = "test";
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
                };
          };
    }

let make_message_end usage =
  Pera_core.Agent_types.AE_message_end
    {
      message =
        Real
          (Pera_connector.Connector.AssistantMessage
             Pera_types.Types.
               {
                 content = [ AText "done" ];
                 stop_reason = EndTurn;
                 provenance =
                   {
                     protocol = "test";
                     provider = "test";
                     model = "claude-sonnet";
                     error_message = None;
                   };
                 usage;
               });
    }

let test_text_delta () =
  let r = Pera_cli.Event_renderer.create ~output:default_output ~json:false in
  let lines = Pera_cli.Event_renderer.render r (make_text_delta "hello") in
  Alcotest.(check (list string)) "text delta" [ "hello" ] lines

let test_thinking_suppressed () =
  let r = Pera_cli.Event_renderer.create ~output:default_output ~json:false in
  let lines =
    Pera_cli.Event_renderer.render r (make_thinking_delta "thinking...")
  in
  Alcotest.(check (list string)) "thinking suppressed" [] lines

let test_thinking_shown () =
  let output =
    Pera_cli.Pera_config.
      { show_thinking = Some true; quiet = None }
  in
  let r = Pera_cli.Event_renderer.create ~output ~json:false in
  let lines =
    Pera_cli.Event_renderer.render r (make_thinking_delta "thinking...")
  in
  Alcotest.(check (list string)) "thinking shown" [ "thinking..." ] lines

let test_tool_start_quiet () =
  let output =
    Pera_cli.Pera_config.
      { show_thinking = None; quiet = Some true }
  in
  let r = Pera_cli.Event_renderer.create ~output ~json:false in
  let event =
    Pera_core.Agent_types.AE_tool_execution_start
      { tool_call_id = "1"; tool_name = "bash"; args = `Null }
  in
  let lines = Pera_cli.Event_renderer.render r event in
  Alcotest.(check (list string)) "tool start quiet" [] lines

let test_tool_start_visible () =
  let r = Pera_cli.Event_renderer.create ~output:default_output ~json:false in
  let event =
    Pera_core.Agent_types.AE_tool_execution_start
      { tool_call_id = "1"; tool_name = "bash"; args = `Null }
  in
  let lines = Pera_cli.Event_renderer.render r event in
  Alcotest.(check (list string)) "tool start visible" [ "\n[tool: bash]" ] lines

let test_json_mode () =
  let r = Pera_cli.Event_renderer.create ~output:default_output ~json:true in
  let lines = Pera_cli.Event_renderer.render r (make_text_delta "hello") in
  match lines with
  | [ line ] -> (
      let json = Yojson.Safe.from_string line in
      match json with
      | `Assoc fields -> (
          match List.find_opt (fun (k, _) -> String.equal k "type") fields with
          | Some (_, `String "text_delta") -> ()
          | _ -> Alcotest.fail "expected type=text_delta")
      | _ -> Alcotest.fail "expected JSON object")
  | _ -> Alcotest.fail "expected one line"

let test_stats () =
  let r = Pera_cli.Event_renderer.create ~output:default_output ~json:false in
  let usage =
    Pera_types.Types.
      {
        input_tokens = 100;
        output_tokens = 50;
        cache_read_tokens = 10;
        cache_write_tokens = 5;
        cost_usd = None;
      }
  in
  let _ = Pera_cli.Event_renderer.render r (make_message_end usage) in
  let s = Pera_cli.Event_renderer.stats r in
  Alcotest.(check bool)
    "contains model" true
    (String.mem ~sub:"claude-sonnet" s);
  Alcotest.(check bool) "contains input" true (String.mem ~sub:"In: 100" s);
  Alcotest.(check bool) "contains output" true (String.mem ~sub:"Out: 50" s)

let test_stats_turn_counter () =
  let r = Pera_cli.Event_renderer.create ~output:default_output ~json:false in
  let turn_end =
    Pera_core.Agent_types.AE_turn_end
      {
        message =
          Pera_core.Agent_types.Synthetic
            (Pera_core.Agent_types.Compaction_summary { summary = "" });
        tool_results = [];
      }
  in
  let _ = Pera_cli.Event_renderer.render r turn_end in
  let _ = Pera_cli.Event_renderer.render r turn_end in
  let s = Pera_cli.Event_renderer.stats r in
  Alcotest.(check bool) "turn counter" true (String.mem ~sub:"Turns: 2" s)

let () =
  Alcotest.run "event_renderer"
    [
      ( "render",
        [
          Alcotest.test_case "text delta" `Quick test_text_delta;
          Alcotest.test_case "thinking suppressed" `Quick
            test_thinking_suppressed;
          Alcotest.test_case "thinking shown" `Quick test_thinking_shown;
          Alcotest.test_case "tool start quiet" `Quick test_tool_start_quiet;
          Alcotest.test_case "tool start visible" `Quick test_tool_start_visible;
          Alcotest.test_case "json mode" `Quick test_json_mode;
        ] );
      ( "stats",
        [
          Alcotest.test_case "accumulates" `Quick test_stats;
          Alcotest.test_case "turn counter" `Quick test_stats_turn_counter;
        ] );
    ]
