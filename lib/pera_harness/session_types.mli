(** Session entry type definitions and JSON codec.

    All session entries share common fields: [id] (a UUIDv7 string), [type] (a
    discriminant string), and [timestamp] (Unix epoch seconds as float). The
    [parent_id] field is included only when [Some]; absent fields are omitted
    entirely from the JSON — never serialised as [null]. *)

type entry_id = Entry_id.t

type session_info_entry = {
  id : entry_id;
  timestamp : float;
  session_id : string;
  cwd : string;
  model : Pera_types.Types.model;
  parent_session_id : string option;
}

type message_entry = {
  id : entry_id;
  parent_id : entry_id option;
  timestamp : float;
  message : Pera_provider.Provider.message;
}

type leaf_entry = {
  id : entry_id;
  parent_id : entry_id option;
  timestamp : float;
}

type model_change_entry = {
  id : entry_id;
  parent_id : entry_id option;
  timestamp : float;
  model : Pera_types.Types.model;
}

type thinking_level_change_entry = {
  id : entry_id;
  parent_id : entry_id option;
  timestamp : float;
  thinking_enabled : bool;
}

type compaction_entry = {
  id : entry_id;
  parent_id : entry_id option;
  timestamp : float;
  summary : string;
  first_kept_entry_id : entry_id;
}

type session_entry =
  | SessionInfo of session_info_entry
  | Message of message_entry
  | Leaf of leaf_entry
  | ModelChange of model_change_entry
  | ThinkingLevelChange of thinking_level_change_entry
  | Compaction of compaction_entry

val entry_to_json : session_entry -> Yojson.Safe.t
(** [entry_to_json e] serialises [e] to a JSON object with [id], [type], and
    [timestamp] fields plus variant-specific fields. [parent_id] is included
    only when [Some]; absent optionals are omitted, not set to [null]. *)

val message_to_json : Pera_provider.Provider.message -> Yojson.Safe.t
(** [message_to_json m] serialises a provider message to the session JSON
    format. [cost_usd] is serialised as a JSON string via [Decimal.to_string]
    when [Some]; the key is omitted entirely when [None]. *)
