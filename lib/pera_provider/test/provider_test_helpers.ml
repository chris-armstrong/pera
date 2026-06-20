open Containers
open Pera_types
open Pera_provider

(** Look up the value for [key] in an assoc list, failing the test if absent. *)
let assoc_exn key fields =
  List.assoc_opt ~eq:String.equal key fields
  |> Option.get_exn_or (Fmt.str "expected key %S in assoc" key)

(** Unwrap a [`Assoc] JSON value, failing the test if it is not an assoc. *)
let as_assoc label json =
  match json with
  | `Assoc fields -> fields
  | other ->
      Alcotest.failf "%s: expected JSON object, got %s" label
        (Yojson.Safe.to_string other)

(** Unwrap a [`List] JSON value, failing the test if it is not a list. *)
let as_list label json =
  match json with
  | `List items -> items
  | other ->
      Alcotest.failf "%s: expected JSON array, got %s" label
        (Yojson.Safe.to_string other)

(** Unwrap a [`String] JSON value, failing the test if it is not a string. *)
let as_string label json =
  match json with
  | `String s -> s
  | other ->
      Alcotest.failf "%s: expected JSON string, got %s" label
        (Yojson.Safe.to_string other)

(** Build a minimal [Provider.context] around a message list. *)
let make_context messages =
  { Provider.system = ""; messages; tools = []; thinking = false }

(** Build a minimal [Provider.simple_stream_options]. *)
let make_options () =
  {
    Provider.max_tokens = 1024;
    temperature = None;
    cache_policy = Types.No_cache;
    cache_ttl = Types.Five_minutes;
  }

(** A minimal model value. *)
let test_model =
  { Types.id = "test-model"; api = "anthropic"; context_window = 200_000 }

(** Build a [ToolResultMessage] with string content. *)
let make_tool_result ?(is_error = false) tool_call_id content_str =
  Provider.ToolResultMessage
    { Types.tool_call_id; content = `String content_str; is_error }
