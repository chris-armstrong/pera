(** Shared test helpers for pera_provider test suites.

    This module provides JSON navigation utilities, minimal [Provider] value
    builders, and [ToolResultMessage] constructors that are used across multiple
    pera_provider test files. *)

(** {2 JSON navigation helpers} *)

val assoc_exn : string -> (string * Yojson.Safe.t) list -> Yojson.Safe.t
(** [assoc_exn key fields] looks up [key] in an association list, calling
    {!Alcotest.fail} if the key is absent. *)

val as_assoc : string -> Yojson.Safe.t -> (string * Yojson.Safe.t) list
(** [as_assoc label json] unwraps a [`Assoc] JSON value, calling
    {!Alcotest.failf} with [label] if [json] is not an object. *)

val as_list : string -> Yojson.Safe.t -> Yojson.Safe.t list
(** [as_list label json] unwraps a [`List] JSON value, calling {!Alcotest.failf}
    with [label] if [json] is not an array. *)

val as_string : string -> Yojson.Safe.t -> string
(** [as_string label json] unwraps a [`String] JSON value, calling
    {!Alcotest.failf} with [label] if [json] is not a string. *)

(** {2 Provider value builders} *)

val make_context :
  Pera_provider.Provider.message list -> Pera_provider.Provider.context
(** [make_context messages] builds a minimal [Provider.context] wrapping
    [messages] with an empty system prompt and no tools. *)

val make_options : unit -> Pera_provider.Provider.simple_stream_options
(** [make_options ()] builds a minimal [Provider.simple_stream_options] with
    [max_tokens = 1024] and no temperature override. *)

val test_model : Pera_types.Types.model
(** A minimal model value for use in tests. *)

(** {2 Message builders} *)

val make_tool_result :
  ?is_error:bool -> string -> string -> Pera_provider.Provider.message
(** [make_tool_result ?is_error tool_call_id content_str] builds a
    [ToolResultMessage] with string content. [is_error] defaults to [false]. *)
