open Containers [@@warning "-33"]
open Pera_core
open Pera_core_test_util
open Agent_loop_helpers

(** Check whether an event is [AE_tool_execution_start]. *)
let is_tool_execution_start = function
  | Agent_types.AE_tool_execution_start _ -> true
  | _ -> false

(** Check whether an event is [AE_tool_execution_end]. *)
let is_tool_execution_end = function
  | Agent_types.AE_tool_execution_end _ -> true
  | _ -> false

(** Extract tool_name from a [AE_tool_execution_end] event. Returns None for
    other events. *)
let tool_execution_end_name = function
  | Agent_types.AE_tool_execution_end { tool_name; _ } -> Some tool_name
  | _ -> None

(** Build a minimal loop config with tools and sensible defaults. *)
let make_config ?(before_tool_call = None) ?(after_tool_call = None)
    ?(tool_execution = `Parallel) tools stream_fn =
  Agent_loop.
    {
      model = test_model;
      system = "test system";
      options = test_options;
      stream_fn;
      convert_to_llm = default_convert_to_llm;
      tool_ctx = ();
      tools;
      tool_execution;
      transform_context = None;
      get_api_key = None;
      before_tool_call;
      after_tool_call;
      should_stop_after_turn = None;
      prepare_next_turn = None;
      get_steering_messages = None;
      get_follow_up_messages = None;
    }

(** Make a simple tool that returns Tool_text and records invocations. *)
let make_simple_tool name execute_fn =
  Agent_types.Tool.create ~name ~description:"test tool" ~schema:empty_schema
    ~parallel_safe:true ~execute:execute_fn

(** {1 Test 1: single tool call executes and feeds result back} *)

let test_single_tool_call_executes_and_feeds_result_back () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let executed = ref false in
  let tool =
    make_simple_tool "echo" (fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
        executed := true;
        Ok (Agent_types.Tool_text "echo result"))
  in
  (* Turn 1: tool use; turn 2: end turn *)
  let tc = make_tool_call "call-1" "echo" (`Assoc []) in
  let script1 = make_tool_use_turn_script [ tc ] in
  let script2 = make_text_turn_script "done" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config [ tool ] stream_fn in
  let loop_stream =
    Agent_loop.run config ~messages:[ make_user_agent_message "go" ] ~sw
  in
  let events, _result = collect_agent_events loop_stream in
  (* Tool was executed *)
  Alcotest.(check bool) "tool was executed" true !executed;
  (* AE_tool_execution_start fired *)
  Alcotest.(check bool)
    "tool_execution_start event fired" true
    (List.exists is_tool_execution_start events);
  (* AE_tool_execution_end fired with is_error=false *)
  let end_events =
    List.filter_map
      (fun e ->
        match e with
        | Agent_types.AE_tool_execution_end
            { tool_call_id; tool_name; result; is_error } ->
            Some (tool_call_id, tool_name, result, is_error)
        | _ -> None)
      events
  in
  Alcotest.(check int) "one tool_execution_end event" 1 (List.length end_events);
  let _id, _name, _result, is_error =
    List.nth_opt end_events 0 |> Option.get_exn_or "expected tool_execution_end"
  in
  Alcotest.(check bool) "tool_execution_end is_error=false" false is_error;
  (* Turn 2's recorded context includes the ToolResultMessage *)
  let recorded = Faux_provider.recorded_contexts () in
  Alcotest.(check int) "two turns recorded" 2 (List.length recorded);
  let second_ctx =
    List.nth_opt recorded 1
    |> Option.get_exn_or "expected second recorded context"
  in
  let has_tool_result =
    List.exists
      (fun msg ->
        match msg with
        | Pera_connector.Connector.ToolResultMessage _ -> true
        | _ -> false)
      second_ctx.Pera_connector.Connector.messages
  in
  Alcotest.(check bool)
    "second turn context contains ToolResultMessage" true has_tool_result

(** {1 Test 2: parallel tool results appended in source order} *)

(** For the parallel ordering test, we need two tools where tool 2 completes
    before tool 1. We use Eio.Condition to coordinate: tool 1 waits on
    cond_release_1 (signalled after tool 2 finishes), tool 2 runs freely. *)
let test_parallel_tool_results_appended_in_source_order () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  (* Condition to coordinate: we signal it after tool 2 runs to release tool 1 *)
  let mutex = Eio.Mutex.create () in
  let cond = Eio.Condition.create () in
  let tool2_done = ref false in
  let completion_order : string list ref = ref [] in
  (* Tool 1: waits until tool 2 has run, then completes *)
  let tool1 =
    Agent_types.Tool.create ~name:"tool1" ~description:"tool that waits"
      ~schema:empty_schema ~parallel_safe:true
      ~execute:
        (fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
          (* Wait until tool2 signals *)
          Eio.Mutex.use_rw ~protect:false mutex (fun () ->
              while not !tool2_done do
                Eio.Condition.await cond mutex
              done);
          completion_order := !completion_order @ [ "tool1" ];
          Ok (Agent_types.Tool_text "result1"))
  in
  (* Tool 2: runs freely and signals tool 1 *)
  let tool2 =
    Agent_types.Tool.create ~name:"tool2" ~description:"fast tool"
      ~schema:empty_schema ~parallel_safe:true
      ~execute:
        (fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
          (* Signal tool1 to proceed *)
          Eio.Mutex.use_rw ~protect:false mutex (fun () ->
              tool2_done := true;
              Eio.Condition.broadcast cond);
          completion_order := !completion_order @ [ "tool2" ];
          Ok (Agent_types.Tool_text "result2"))
  in
  let tc1 = make_tool_call "call-1" "tool1" (`Assoc []) in
  let tc2 = make_tool_call "call-2" "tool2" (`Assoc []) in
  (* Turn 1 issues both calls; turn 2 ends *)
  let script1 = make_tool_use_turn_script [ tc1; tc2 ] in
  let script2 = make_text_turn_script "done" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config [ tool1; tool2 ] stream_fn in
  let loop_stream =
    Agent_loop.run config ~messages:[ make_user_agent_message "go" ] ~sw
  in
  let events, _result = collect_agent_events loop_stream in
  (* tool_execution_end events should fire in completion order: tool2 before
     tool1 *)
  let end_names = List.filter_map tool_execution_end_name events in
  Alcotest.(check int) "two tool_execution_end events" 2 (List.length end_names);
  let first_end =
    List.nth_opt end_names 0 |> Option.get_exn_or "expected first end event"
  in
  let second_end =
    List.nth_opt end_names 1 |> Option.get_exn_or "expected second end event"
  in
  Alcotest.(check string)
    "tool2 completes first (completion order)" "tool2" first_end;
  Alcotest.(check string)
    "tool1 completes second (completion order)" "tool1" second_end;
  (* Turn 2 recorded context: tool results should be in source order:
     tool1 result first, tool2 result second *)
  let recorded = Faux_provider.recorded_contexts () in
  Alcotest.(check int) "two turns" 2 (List.length recorded);
  let second_ctx =
    List.nth_opt recorded 1
    |> Option.get_exn_or "expected second recorded context"
  in
  let tool_result_msgs =
    List.filter_map
      (fun msg ->
        match msg with
        | Pera_connector.Connector.ToolResultMessage tr -> Some tr
        | _ -> None)
      second_ctx.Pera_connector.Connector.messages
  in
  Alcotest.(check int)
    "two tool result messages" 2
    (List.length tool_result_msgs);
  let first_tr =
    List.nth_opt tool_result_msgs 0
    |> Option.get_exn_or "expected first tool result"
  in
  let second_tr =
    List.nth_opt tool_result_msgs 1
    |> Option.get_exn_or "expected second tool result"
  in
  (* Source order: call-1 (tool1) first, call-2 (tool2) second *)
  Alcotest.(check string)
    "first result is call-1 (source order)" "call-1" first_tr.tool_call_id;
  Alcotest.(check string)
    "second result is call-2 (source order)" "call-2" second_tr.tool_call_id

(** {1 Test 3: sequential mode runs in source order without overlap} *)

let test_sequential_mode_runs_in_source_order () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let start_order : string list ref = ref [] in
  let tool1 =
    Agent_types.Tool.create ~name:"tool1" ~description:"first tool"
      ~schema:empty_schema ~parallel_safe:false
      ~execute:
        (fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
          start_order := !start_order @ [ "tool1" ];
          Ok (Agent_types.Tool_text "r1"))
  in
  let tool2 =
    Agent_types.Tool.create ~name:"tool2" ~description:"second tool"
      ~schema:empty_schema ~parallel_safe:false
      ~execute:
        (fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
          start_order := !start_order @ [ "tool2" ];
          Ok (Agent_types.Tool_text "r2"))
  in
  let tc1 = make_tool_call "c1" "tool1" (`Assoc []) in
  let tc2 = make_tool_call "c2" "tool2" (`Assoc []) in
  let script1 = make_tool_use_turn_script [ tc1; tc2 ] in
  let script2 = make_text_turn_script "done" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  (* Use Sequential execution mode *)
  let config =
    make_config ~tool_execution:`Sequential [ tool1; tool2 ] stream_fn
  in
  let loop_stream =
    Agent_loop.run config ~messages:[ make_user_agent_message "go" ] ~sw
  in
  let events, _result = collect_agent_events loop_stream in
  (* Both tools executed *)
  Alcotest.(check int)
    "two tool_execution_end events" 2
    (List.length (List.filter is_tool_execution_end events));
  (* Start order matches source order *)
  let order = !start_order in
  Alcotest.(check int) "two starts" 2 (List.length order);
  let first =
    List.nth_opt order 0 |> Option.get_exn_or "expected first start"
  in
  let second =
    List.nth_opt order 1 |> Option.get_exn_or "expected second start"
  in
  Alcotest.(check string) "tool1 starts first (source order)" "tool1" first;
  Alcotest.(check string) "tool2 starts second (source order)" "tool2" second

(** {1 Test 4: per-tool sequential forces batch sequential} *)

let test_per_tool_sequential_forces_batch_sequential () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let start_order : string list ref = ref [] in
  (* tool1 is Sequential; tool2 is Parallel — but the batch should be
     sequential because tool1 is Sequential *)
  let tool1 =
    Agent_types.Tool.create ~name:"tool1" ~description:"sequential tool"
      ~schema:empty_schema ~parallel_safe:false
      ~execute:
        (fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
          start_order := !start_order @ [ "tool1" ];
          Ok (Agent_types.Tool_text "r1"))
  in
  let tool2 =
    Agent_types.Tool.create ~name:"tool2" ~description:"parallel tool"
      ~schema:empty_schema ~parallel_safe:true
      ~execute:
        (fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
          start_order := !start_order @ [ "tool2" ];
          Ok (Agent_types.Tool_text "r2"))
  in
  let tc1 = make_tool_call "c1" "tool1" (`Assoc []) in
  let tc2 = make_tool_call "c2" "tool2" (`Assoc []) in
  let script1 = make_tool_use_turn_script [ tc1; tc2 ] in
  let script2 = make_text_turn_script "done" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  (* Config default is Parallel, but tool1 is Sequential — forces sequential *)
  let config =
    make_config ~tool_execution:`Parallel [ tool1; tool2 ] stream_fn
  in
  let loop_stream =
    Agent_loop.run config ~messages:[ make_user_agent_message "go" ] ~sw
  in
  let events, _result = collect_agent_events loop_stream in
  Alcotest.(check int)
    "two tool_execution_end events" 2
    (List.length (List.filter is_tool_execution_end events));
  (* Because batch is forced sequential, tool1 must start before tool2 *)
  let order = !start_order in
  Alcotest.(check int) "two starts" 2 (List.length order);
  let first =
    List.nth_opt order 0 |> Option.get_exn_or "expected first start"
  in
  Alcotest.(check string) "tool1 starts first (forced sequential)" "tool1" first

(** {1 Test 5: schema validation failure produces error result without calling
    execute} *)

let test_schema_validation_failure_becomes_error_result_without_execute () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let execute_count = ref 0 in
  (* Tool expects {x: integer} but we pass {x: "not-an-int"} — a string that
     cannot be coerced to integer *)
  let tool =
    Agent_types.Tool.create ~name:"typed_tool"
      ~description:"tool with int schema" ~schema:int_field_schema
      ~parallel_safe:true
      ~execute:
        (fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
          incr execute_count;
          Ok (Agent_types.Tool_text "ok"))
  in
  (* Pass a string that cannot be parsed as a number — should fail validation *)
  let bad_args = `Assoc [ ("x", `String "not-an-int") ] in
  let tc = make_tool_call "c1" "typed_tool" bad_args in
  let script1 = make_tool_use_turn_script [ tc ] in
  let script2 = make_text_turn_script "done" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config [ tool ] stream_fn in
  let loop_stream =
    Agent_loop.run config ~messages:[ make_user_agent_message "go" ] ~sw
  in
  let events, _result = collect_agent_events loop_stream in
  (* execute should NOT have been called *)
  Alcotest.(check int)
    "execute not called on schema validation failure" 0 !execute_count;
  (* But there should be a tool_execution_end with is_error=true *)
  let end_events =
    List.filter_map
      (fun e ->
        match e with
        | Agent_types.AE_tool_execution_end { is_error; _ } -> Some is_error
        | _ -> None)
      events
  in
  Alcotest.(check int)
    "one tool_execution_end event (for the error)" 1 (List.length end_events);
  let is_error =
    List.nth_opt end_events 0 |> Option.get_exn_or "expected tool_execution_end"
  in
  Alcotest.(check bool)
    "tool_execution_end is_error=true for schema failure" true is_error

(** {1 Test 6: before_tool_call Deny short-circuits with error result} *)

let test_before_tool_call_deny_short_circuits_with_error_result () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let execute_count = ref 0 in
  let tool =
    make_simple_tool "some_tool" (fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
        incr execute_count;
        Ok (Agent_types.Tool_text "ok"))
  in
  let before_tool_call =
    Some
      (fun (_ctx : unit Agent_loop.before_tool_call_ctx) ->
        Agent_types.Deny "nope")
  in
  let tc = make_tool_call "c1" "some_tool" (`Assoc []) in
  let script1 = make_tool_use_turn_script [ tc ] in
  let script2 = make_text_turn_script "done" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config ~before_tool_call [ tool ] stream_fn in
  let loop_stream =
    Agent_loop.run config ~messages:[ make_user_agent_message "go" ] ~sw
  in
  let events, _result = collect_agent_events loop_stream in
  (* execute was NOT called *)
  Alcotest.(check int) "execute not called (Deny)" 0 !execute_count;
  (* tool_execution_end fired with is_error=true and content contains "nope" *)
  let end_events =
    List.filter_map
      (fun e ->
        match e with
        | Agent_types.AE_tool_execution_end { is_error; result; _ } ->
            Some (is_error, result)
        | _ -> None)
      events
  in
  Alcotest.(check int) "one tool_execution_end" 1 (List.length end_events);
  let is_error, result =
    List.nth_opt end_events 0 |> Option.get_exn_or "expected tool_execution_end"
  in
  Alcotest.(check bool) "is_error=true" true is_error;
  (* The result content should mention "nope" *)
  let result_str =
    match result with `String s -> s | other -> Yojson.Safe.to_string other
  in
  Alcotest.(check bool)
    "result contains 'nope'" true
    (String.find ~sub:"nope" result_str >= 0)

(** {1 Test 7: tool raising is caught as error result} *)

let test_tool_raising_is_caught_as_error_result () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let tool =
    make_simple_tool "exploding_tool" (fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
        failwith "boom!")
  in
  let tc = make_tool_call "c1" "exploding_tool" (`Assoc []) in
  let script1 = make_tool_use_turn_script [ tc ] in
  let script2 = make_text_turn_script "done" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config [ tool ] stream_fn in
  let loop_stream =
    Agent_loop.run config ~messages:[ make_user_agent_message "go" ] ~sw
  in
  let events, result = collect_agent_events loop_stream in
  (* run should complete (not raise) *)
  (match result with
  | Error (err_msg, _stop_err) ->
      Alcotest.failf "expected Ok result after tool exception, got Error: %s"
        err_msg
  | Ok _ -> ());
  (* tool_execution_end is_error=true *)
  let end_events =
    List.filter_map
      (fun e ->
        match e with
        | Agent_types.AE_tool_execution_end { is_error; _ } -> Some is_error
        | _ -> None)
      events
  in
  Alcotest.(check int) "one tool_execution_end" 1 (List.length end_events);
  let is_error =
    List.nth_opt end_events 0 |> Option.get_exn_or "expected tool_execution_end"
  in
  Alcotest.(check bool) "is_error=true for raised exception" true is_error;
  (* agent_end was emitted — run reached the end *)
  let agent_end_events =
    List.filter
      (fun e -> match e with Agent_types.AE_agent_end _ -> true | _ -> false)
      events
  in
  Alcotest.(check int)
    "agent_end emitted (run completed)" 1
    (List.length agent_end_events)

(** {1 Test 8: after_tool_call hook invoked per executed tool} *)

let test_after_tool_call_hook_invoked_per_result () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let after_count = ref 0 in
  let after_tool_call =
    Some (fun (_ctx : unit Agent_loop.after_tool_call_ctx) -> incr after_count)
  in
  let tool1 =
    make_simple_tool "tool1" (fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
        Ok (Agent_types.Tool_text "r1"))
  in
  let tool2 =
    make_simple_tool "tool2" (fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
        Ok (Agent_types.Tool_text "r2"))
  in
  let tc1 = make_tool_call "c1" "tool1" (`Assoc []) in
  let tc2 = make_tool_call "c2" "tool2" (`Assoc []) in
  let script1 = make_tool_use_turn_script [ tc1; tc2 ] in
  let script2 = make_text_turn_script "done" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config ~after_tool_call [ tool1; tool2 ] stream_fn in
  let loop_stream =
    Agent_loop.run config ~messages:[ make_user_agent_message "go" ] ~sw
  in
  let _events, _result = collect_agent_events loop_stream in
  (* after_tool_call should have been called once per tool (2 tools) *)
  Alcotest.(check int) "after_tool_call count = 2" 2 !after_count

let () =
  Alcotest.run "agent_loop_tools"
    [
      ( "tool-execution",
        [
          Alcotest.test_case "single tool call executes and feeds result back"
            `Quick test_single_tool_call_executes_and_feeds_result_back;
          Alcotest.test_case "parallel tool results appended in source order"
            `Quick test_parallel_tool_results_appended_in_source_order;
          Alcotest.test_case "sequential mode runs in source order" `Quick
            test_sequential_mode_runs_in_source_order;
          Alcotest.test_case "per-tool sequential forces batch sequential"
            `Quick test_per_tool_sequential_forces_batch_sequential;
        ] );
      ( "tool-validation-and-hooks",
        [
          Alcotest.test_case
            "schema validation failure produces error result without execute"
            `Quick
            test_schema_validation_failure_becomes_error_result_without_execute;
          Alcotest.test_case
            "before_tool_call Deny short-circuits with error result" `Quick
            test_before_tool_call_deny_short_circuits_with_error_result;
          Alcotest.test_case "tool raising is caught as error result" `Quick
            test_tool_raising_is_caught_as_error_result;
          Alcotest.test_case "after_tool_call hook invoked per result" `Quick
            test_after_tool_call_hook_invoked_per_result;
        ] );
    ]
