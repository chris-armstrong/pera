open Containers
open Pera_types
open Pera_connector

(* ── helpers ────────────────────────────────────────────────────────────── *)

let test_model =
  Types.{ id = "claude-test"; api = "anthropic"; context_window = 200_000 }

let make_context ?(tools = []) ?(system = "") messages =
  Pera_connector.Connector.
    { system; messages; tools }

let make_options () =
  Pera_connector.Connector.
    {
      max_tokens = 1024;
      temperature = None;
      cache_policy = Types.No_cache;
      cache_ttl = Types.Five_minutes;
        thinking_budget_tokens = None;
    }

let string_testable = Alcotest.testable Format.pp_print_string String.equal

let tool_schema name description schema =
  Pera_connector.Connector.{ name; description; schema }

(* ── Anthropic tool wrapping ───────────────────────────────────────────── *)

(** Anthropic request body [tools] array uses canonical alphabetical field
    order: [description], [input_schema], [name]. *)
let test_anthropic_request_body_tools_are_canonical () =
  let schema =
    Json_schema.object_
      ~properties:
        [
          ("z", Json_schema.string ());
          ("a", Json_schema.integer ());
        ]
      ~required:[ "z"; "a" ] ()
  in
  let tool = tool_schema "my_tool" "Does a thing." schema in
  let context = make_context [] ~tools:[ tool ] in
  let body =
    Anthropic_request.build_request_body ~model:test_model ~context
      ~options:(make_options ())
  in
  let fields = match body with `Assoc pairs -> pairs | _ -> [] in
  let tools_json =
    List.assoc_opt ~eq:String.equal "tools" fields
    |> Option.get_exn_or "expected tools field"
  in
  let tool_str = Yojson.Safe.to_string tools_json in
  let expected =
    {|[{"description":"Does a thing.","input_schema":{"properties":{"a":{"type":"integer"},"z":{"type":"string"}},"required":["a","z"],"type":"object"},"name":"my_tool"}]|}
  in
  Alcotest.check string_testable "anthropic tools array canonical" expected
    tool_str

(* ── OpenAI completions tool wrapping ──────────────────────────────────── *)

(** OpenAI chat-completions request body [tools] array uses canonical
    alphabetical field order inside the [function] object:
    [description], [name], [parameters]. *)
let test_openai_request_body_tools_are_canonical () =
  let schema =
    Json_schema.object_
      ~properties:
        [
          ("z", Json_schema.string ());
          ("a", Json_schema.integer ());
        ]
      ~required:[ "z"; "a" ] ()
  in
  let tool = tool_schema "my_tool" "Does a thing." schema in
  let context = make_context [] ~tools:[ tool ] in
  let model =
    Types.{ id = "gpt-4"; api = "openai-completions"; context_window = 8_192 }
  in
  let body =
    Openai_completions_request.build_request_body ~model ~context
      ~options:(make_options ())
      ~compat:Openai_completions_request.default_compat
  in
  let fields = match body with `Assoc pairs -> pairs | _ -> [] in
  let tools_json =
    List.assoc_opt ~eq:String.equal "tools" fields
    |> Option.get_exn_or "expected tools field"
  in
  let tool_str = Yojson.Safe.to_string tools_json in
  let expected =
    {|[{"function":{"description":"Does a thing.","name":"my_tool","parameters":{"properties":{"a":{"type":"integer"},"z":{"type":"string"}},"required":["a","z"],"type":"object"}},"type":"function"}]|}
  in
  Alcotest.check string_testable "openai tools array canonical" expected
    tool_str

(* ── Test runner ────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "tool_canonical"
    [
      ( "anthropic",
        [
          Alcotest.test_case "request_body_tools_are_canonical" `Quick
            test_anthropic_request_body_tools_are_canonical;
        ] );
      ( "openai_completions",
        [
          Alcotest.test_case "request_body_tools_are_canonical" `Quick
            test_openai_request_body_tools_are_canonical;
        ] );
    ]
