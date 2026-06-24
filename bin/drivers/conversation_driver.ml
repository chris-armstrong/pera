open Containers
open Pera_core
open Pera_connector
open Pera_types

let src = Logs.Src.create "pera.driver.conversation" ~doc:"Conversation driver"

module Log = (val Logs.src_log src : Logs.LOG)

(** Build the provider registry from available API keys. *)
let build_registry () =
  let registry = ref Connector_registry.empty in
  (match Sys.getenv_opt "ANTHROPIC_API_KEY" with
  | Some _ ->
      registry :=
        Connector_registry.register !registry ~name:"anthropic"
          (module Anthropic_connector)
  | None -> ());
  (match Sys.getenv_opt "OPENAI_API_KEY" with
  | Some _ ->
      registry :=
        Connector_registry.register !registry ~name:"openai-completions"
          (module Openai_completions_connector)
  | None -> ());
  !registry

(** Select the model based on available providers and an optional CLI argument.
*)
let select_model registry argv =
  if Array.length argv > 1 then (
    let api = argv.(1) in
    match api with
    | "anthropic" ->
        Types.
          {
            id = "claude-haiku-4-5-20251001";
            api = "anthropic";
            context_window = 200_000;
          }
    | "openai-completions" ->
        Types.
          {
            id = "kimi-k2.6";
            api = "openai-completions";
            context_window = 128_000;
          }
    | _ ->
        Log.err (fun m -> m "unknown provider: %s" api);
        Log.err (fun m -> m "available: anthropic | openai-completions");
        exit 1)
  else
    (* Default to the first registered provider. *)
    match Connector_registry.to_list registry with
    | ("anthropic", _) :: _ ->
        Types.
          {
            id = "claude-haiku-4-5-20251001";
            api = "anthropic";
            context_window = 200_000;
          }
    | ("openai-completions", _) :: _ ->
        Types.
          {
            id = "kimi-k2.6";
            api = "openai-completions";
            context_window = 128_000;
          }
    | (name, _) :: _ ->
        (* Fallback: use whatever was registered first.
           TODO: 200K is a guess for the unknown provider; surface a CLI flag. *)
        Types.{ id = "unknown"; api = name; context_window = 200_000 }
    | [] ->
        (* Should not reach here — we checked for empty registry before. *)
        print_endline "skipped: no API keys";
        exit 0

let () =
  Driver_log.setup ();
  let registry = build_registry () in
  if List.is_empty (Connector_registry.to_list registry) then (
    print_endline "skipped: no API keys";
    exit 0);
  let argv = Sys.argv in
  let model = select_model registry argv in
  let scenario_name = if Array.length argv > 2 then Some argv.(2) else None in
  Printf.printf "provider: %s\n%!" model.Types.api;
  Printf.printf "model:    %s\n%!" model.Types.id;
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let adapter = Connector_adapter.create ~registry ~api_key:(Option.get_exn_or "ANTHROPIC_API_KEY" (Sys.getenv_opt "ANTHROPIC_API_KEY")) ~env ~sw in
  let stream_fn = Connector_adapter.stream_fn adapter in
  let results =
    match scenario_name with
    | Some name ->
        Conversation_driver_helpers.run_named_scenario name ~model stream_fn sw
    | None -> Conversation_driver_helpers.run_all_scenarios ~model stream_fn sw
  in
  Printf.printf "\n=== Summary ===\n%!";
  List.iter
    (fun Conversation_driver_helpers.{ name; passed } ->
      Printf.printf "  %-30s %s\n%!" name (if passed then "PASS" else "FAIL"))
    results;
  let all_passed =
    List.for_all
      (fun Conversation_driver_helpers.{ passed; _ } -> passed)
      results
  in
  if all_passed then exit 0 else exit 1
