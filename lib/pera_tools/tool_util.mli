(** Shared tool argument extraction utilities.

    Provides functions for extracting typed values from Yojson.Safe.t
    argument objects. All required-field functions return [result] for
    compatibility with [let*] chains. *)

val get_string :
  string -> Yojson.Safe.t -> (string, Pera_types.Types.tool_error) result
(** [get_string key args] extracts the string value for [key] from the JSON
    object [args]. Returns [Error] if the key is missing or the value is not
    a string. *)

val get_string_opt : string -> Yojson.Safe.t -> string option
(** [get_string_opt key args] extracts an optional string value. Returns
    [None] if the key is absent or the value is not a string. *)

val get_int_opt : string -> Yojson.Safe.t -> int option
(** [get_int_opt key args] extracts an optional integer value. Returns
    [None] if the key is absent or the value is not an integer. *)

val get_float_opt : string -> Yojson.Safe.t -> float option
(** [get_float_opt key args] extracts an optional float value. Accepts
    both JSON numbers (int or float) and returns [None] if the key is
    absent or the value is not a number. *)
