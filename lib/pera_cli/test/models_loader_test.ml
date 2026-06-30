open Containers

let make_provider ~name ~models =
  Pera_cli.Models_config.
    {
      name;
      protocol = name ^ "-api";
      api_key_env = [];
      api = None;
      api_env = None;
      compat = None;
      models;
    }

let make_model ~name ~context_window ~max_tokens =
  Pera_cli.Models_config.
    { name; context_window; max_tokens; thinking = None; cost = None }

(* Test 1: merge preserves unmodified provider *)
let test_merge_preserves_unmodified () =
  let open Pera_cli.Models_config in
  let base =
    {
      providers =
        [
          make_provider ~name:"anthropic"
            ~models:
              [
                make_model ~name:"claude-sonnet-4-6" ~context_window:200000
                  ~max_tokens:16000;
              ];
        ];
    }
  in
  let overlay = { providers = [] } in
  let result = Pera_cli.Models_loader.merge ~base ~overlay in
  Alcotest.(check int) "one provider" 1 (List.length result.providers)

(* Test 2: overlay provider with same name merges model lists *)
let test_merge_same_provider () =
  let open Pera_cli.Models_config in
  let base =
    {
      providers =
        [
          make_provider ~name:"anthropic"
            ~models:
              [
                make_model ~name:"claude-sonnet-4-6" ~context_window:200000
                  ~max_tokens:16000;
              ];
        ];
    }
  in
  let overlay =
    {
      providers =
        [
          make_provider ~name:"anthropic"
            ~models:
              [
                make_model ~name:"claude-3-haiku" ~context_window:200000
                  ~max_tokens:8000;
              ];
        ];
    }
  in
  let result = Pera_cli.Models_loader.merge ~base ~overlay in
  Alcotest.(check int) "one provider" 1 (List.length result.providers);
  match result.providers with
  | [ p ] -> Alcotest.(check int) "two models" 2 (List.length p.models)
  | _ -> Alcotest.fail "expected exactly one provider"

(* Test 3: overlay model replaces matching base model *)
let test_merge_replaces_model () =
  let open Pera_cli.Models_config in
  let base =
    {
      providers =
        [
          make_provider ~name:"anthropic"
            ~models:
              [
                make_model ~name:"claude-sonnet-4-6" ~context_window:200000
                  ~max_tokens:16000;
              ];
        ];
    }
  in
  let overlay =
    {
      providers =
        [
          make_provider ~name:"anthropic"
            ~models:
              [
                {
                  (make_model ~name:"claude-sonnet-4-6" ~context_window:200000
                     ~max_tokens:16000)
                  with
                  max_tokens = 32000;
                };
              ];
        ];
    }
  in
  let result = Pera_cli.Models_loader.merge ~base ~overlay in
  match result.providers with
  | [ p ] -> (
      match p.models with
      | [ m ] -> Alcotest.(check int) "max_tokens updated" 32000 m.max_tokens
      | _ -> Alcotest.fail "expected exactly one model")
  | _ -> Alcotest.fail "expected exactly one provider"

(* Test 4: overlay adds new provider *)
let test_merge_adds_provider () =
  let open Pera_cli.Models_config in
  let base =
    {
      providers =
        [
          make_provider ~name:"anthropic"
            ~models:
              [
                make_model ~name:"claude-sonnet-4-6" ~context_window:200000
                  ~max_tokens:16000;
              ];
        ];
    }
  in
  let overlay =
    {
      providers =
        [
          make_provider ~name:"openai"
            ~models:
              [
                make_model ~name:"gpt-4" ~context_window:128000
                  ~max_tokens:16000;
              ];
        ];
    }
  in
  let result = Pera_cli.Models_loader.merge ~base ~overlay in
  Alcotest.(check int) "two providers" 2 (List.length result.providers)

(* Test 5: resolve_model finds known model *)
let test_resolve_finds_model () =
  let open Pera_cli.Models_config in
  let mf =
    {
      providers =
        [
          make_provider ~name:"anthropic"
            ~models:
              [
                make_model ~name:"claude-sonnet-4-6" ~context_window:200000
                  ~max_tokens:16000;
              ];
        ];
    }
  in
  match
    Pera_cli.Models_loader.resolve_model mf "anthropic/claude-sonnet-4-6"
  with
  | Ok (p, m) ->
      Alcotest.(check string) "provider name" "anthropic" p.name;
      Alcotest.(check string) "model name" "claude-sonnet-4-6" m.name
  | Error e -> Alcotest.fail e

(* Test 6: resolve_model returns Error for unknown provider *)
let test_resolve_unknown_provider () =
  let open Pera_cli.Models_config in
  let mf = { providers = [] } in
  match Pera_cli.Models_loader.resolve_model mf "unknown/model" with
  | Ok _ -> Alcotest.fail "expected error"
  | Error e ->
      Alcotest.check Alcotest.bool "error mentions unknown" true
        (String.mem ~sub:"unknown" e)

(* Test 7: resolve_model returns Error for unknown model *)
let test_resolve_unknown_model () =
  let open Pera_cli.Models_config in
  let mf =
    {
      providers =
        [
          make_provider ~name:"anthropic"
            ~models:
              [
                make_model ~name:"claude-sonnet-4-6" ~context_window:200000
                  ~max_tokens:16000;
              ];
        ];
    }
  in
  match Pera_cli.Models_loader.resolve_model mf "anthropic/unknown-model" with
  | Ok _ -> Alcotest.fail "expected error"
  | Error e ->
      Alcotest.check Alcotest.bool "error mentions unknown" true
        (String.mem ~sub:"unknown" e)

(* Test 8: resolve_model returns Error for unqualified name *)
let test_resolve_unqualified () =
  let open Pera_cli.Models_config in
  let mf = { providers = [] } in
  match Pera_cli.Models_loader.resolve_model mf "just-a-name" with
  | Ok _ -> Alcotest.fail "expected error"
  | Error e ->
      Alcotest.check Alcotest.bool "error mentions qualified" true
        (String.mem ~sub:"provider/model" e)

let suite =
  [
    ( "merge preserves unmodified provider",
      `Quick,
      test_merge_preserves_unmodified );
    ("overlay provider merges model lists", `Quick, test_merge_same_provider);
    ( "overlay model replaces matching base model",
      `Quick,
      test_merge_replaces_model );
    ("overlay adds new provider", `Quick, test_merge_adds_provider);
    ("resolve_model finds known model", `Quick, test_resolve_finds_model);
    ( "resolve_model returns Error for unknown provider",
      `Quick,
      test_resolve_unknown_provider );
    ( "resolve_model returns Error for unknown model",
      `Quick,
      test_resolve_unknown_model );
    ( "resolve_model returns Error for unqualified name",
      `Quick,
      test_resolve_unqualified );
  ]

let () = Alcotest.run "models_loader" [ ("models_loader", suite) ]
