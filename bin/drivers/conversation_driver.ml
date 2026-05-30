open Containers
open Pera_core
open Pera_provider
open Pera_types

(** Build the provider registry from available API keys. *)
let build_registry () =
  let registry = ref Provider_registry.empty in
  (match Sys.getenv_opt "ANTHROPIC_API_KEY" with
  | Some _ ->
      registry :=
        Provider_registry.register !registry ~name:"anthropic"
          (module Anthropic_provider)
  | None -> ());
  (match Sys.getenv_opt "OPENAI_API_KEY" with
  | Some _ ->
      registry :=
        Provider_registry.register !registry ~name:"openai-completions"
          (module Openai_completions_provider)
  | None -> ());
  !registry

(** Select the model based on available providers and an optional CLI argument. *)
let select_model registry argv =
  if Array.length argv > 1 then (
    let api = argv.(1) in
    match api with
    | "anthropic" ->
        Types.{ id = "claude-haiku-4-5-20251001"; api = "anthropic" }
    | "openai-completions" ->
        Types.{ id = "kimi-k2.6"; api = "openai-completions" }
    | _ ->
        Printf.eprintf "unknown provider: %s\n" api;
        Printf.eprintf "available: anthropic | openai-completions\n";
        exit 1)
  else
    (* Default to the first registered provider. *)
    match Provider_registry.to_list registry with
    | ("anthropic", _) :: _ ->
        Types.{ id = "claude-haiku-4-5-20251001"; api = "anthropic" }
    | ("openai-completions", _) :: _ ->
        Types.{ id = "kimi-k2.6"; api = "openai-completions" }
    | (name, _) :: _ ->
        (* Fallback: use whatever was registered first. *)
        Types.{ id = "unknown"; api = name }
    | [] ->
        (* Should not reach here — we checked for empty registry before. *)
        print_endline "skipped: no API keys";
        exit 0

let () =
  Driver_log.setup ();
  let registry = build_registry () in
  if List.is_empty (Provider_registry.to_list registry) then (
    print_endline "skipped: no API keys";
    exit 0);
  let argv = Sys.argv in
  let model = select_model registry argv in
  let scenario_name = if Array.length argv > 2 then Some argv.(2) else None in
  Printf.printf "provider: %s\n%!" model.Types.api;
  Printf.printf "model:    %s\n%!" model.Types.id;
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let adapter = Provider_adapter.create ~registry ~env ~sw in
  let stream_fn = Provider_adapter.stream_fn adapter in
  let results =
    match scenario_name with
    | Some name ->
        Conversation_driver_helpers.run_named_scenario name ~model stream_fn sw
    | None ->
        Conversation_driver_helpers.run_all_scenarios ~model stream_fn sw
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
