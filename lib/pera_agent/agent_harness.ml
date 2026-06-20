open Containers

type t = {
  wrapper : unit Pera_harness.Agent_wrapper.t;
  writer : Pera_harness.Session_writer.t;
  mutable session_info_written : bool;
}

type config = {
  cwd : string;
  model : Pera_types.Types.model;
  session_path : string;
  stream_fn : Pera_core.Agent_types.stream_fn;
  max_tokens : int;
  exec_env : (module Pera_env.Execution_env.S);
}

let build_system_prompt tools =
  let base =
    "You are a helpful coding assistant. Work methodically, verify your \
     understanding before acting, and prefer small targeted changes."
  in
  let descs =
    List.map
      (fun (t : unit Pera_core.Agent_types.tool) ->
        Printf.sprintf "- %s: %s"
          (Pera_core.Agent_types.Tool.name t)
          (Pera_core.Agent_types.Tool.description t))
      tools
  in
  let prompt =
    if List.is_empty descs then base
    else base ^ "\n\nAvailable tools:\n" ^ String.concat "\n" descs
  in
  Pera_core.Cache_lint.warn_if_dynamic ~field:"system prompt" prompt;
  prompt

let convert_to_llm messages =
  List.map Pera_core.Agent_types.to_provider_message messages

let session_subscriber writer event =
  let open Result.Syntax in
  let result =
    match event with
    | Pera_core.Agent_types.AE_message_end
        { message = Real (Pera_provider.Provider.AssistantMessage am) } ->
        Pera_harness.Session_writer.write_message writer
          (Pera_provider.Provider.AssistantMessage am)
    | Pera_core.Agent_types.AE_message_end _ -> Ok ()
    | Pera_core.Agent_types.AE_turn_end { tool_results; _ } ->
        List.fold_left
          (fun acc tr ->
            let* () = acc in
            Pera_harness.Session_writer.write_message writer
              (Pera_provider.Provider.ToolResultMessage tr))
          (Ok ()) tool_results
    | Pera_core.Agent_types.AE_agent_end _ ->
        Pera_harness.Session_writer.write_leaf writer
    | Pera_core.Agent_types.AE_agent_start | Pera_core.Agent_types.AE_turn_start
    | Pera_core.Agent_types.AE_message_start _
    | Pera_core.Agent_types.AE_message_update _
    | Pera_core.Agent_types.AE_tool_execution_start _
    | Pera_core.Agent_types.AE_tool_execution_update _
    | Pera_core.Agent_types.AE_tool_execution_end _ ->
        Ok ()
    | Pera_core.Agent_types.AE_compaction_start -> Ok ()
    | Pera_core.Agent_types.AE_compaction_error _ -> Ok ()
    | Pera_core.Agent_types.AE_compaction_end _ -> Ok ()
    (* Stage 4 will replace this AE_compaction_end stub with the real writer sequence. *)
  in
  match result with
  | Ok () -> ()
  | Error e ->
      Printf.eprintf "session write error: %s\n%!" e.Pera_types.Types.message

let create ~config ~env ~sw =
  let open Result.Syntax in
  let* writer =
    Pera_harness.Session_writer.create ~path:config.session_path ~env
      ~model:config.model ~cwd:config.cwd
  in
  let tools = Pera_tools.Tools.default config.exec_env in
  let loop_config =
    Pera_core.Agent_loop.
      {
        model = config.model;
        system = build_system_prompt tools;
        options =
          Pera_provider.Provider.
            {
              max_tokens = config.max_tokens;
              temperature = None;
              cache_policy = Pera_types.Types.No_cache;
              cache_ttl = Pera_types.Types.Five_minutes;
            };
        stream_fn = config.stream_fn;
        convert_to_llm;
        tool_ctx = ();
        tools;
        tool_execution = `Parallel;
        transform_context = None;
        get_api_key = None;
        before_tool_call = None;
        after_tool_call = None;
        should_stop_after_turn = None;
        prepare_next_turn = None;
        get_steering_messages = None;
        get_follow_up_messages = None;
      }
  in
  let wrapper = Pera_harness.Agent_wrapper.create ~config:loop_config ~sw in
  let _unsub =
    Pera_harness.Agent_wrapper.subscribe wrapper (session_subscriber writer)
  in
  Ok { wrapper; writer; session_info_written = false }

let send t text =
  (if not t.session_info_written then
     match Pera_harness.Session_writer.write_session_info t.writer with
     | Ok () -> t.session_info_written <- true
     | Error e ->
         Printf.eprintf "session_info write: %s\n%!" e.Pera_types.Types.message);
  let um =
    Pera_provider.Provider.UserMessage
      Pera_types.Types.{ role = "user"; content = [ UText text ] }
  in
  (match Pera_harness.Session_writer.write_message t.writer um with
  | Ok () -> ()
  | Error e ->
      Printf.eprintf "user message write: %s\n%!" e.Pera_types.Types.message);
  let agent_msg = Pera_core.Agent_types.Real um in
  let history = Pera_harness.Agent_wrapper.current_messages t.wrapper in
  let messages = history @ [ agent_msg ] in
  Pera_harness.Agent_wrapper.send t.wrapper ~messages

let subscribe t f = Pera_harness.Agent_wrapper.subscribe t.wrapper f
