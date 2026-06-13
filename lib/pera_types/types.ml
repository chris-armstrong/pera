open Containers [@@warning "-33"]

type user_content =
  | UText of string
  | UImage of { url : string; media_type : string }
[@@deriving eq, show]

type assistant_content =
  | AText of string
  | AThinking of { text : string; signature : string option }
  | AToolCall of tool_call

and tool_call = {
  id : string;
  name : string;
  arguments :
    (Yojson.Safe.t
    [@equal Yojson.Safe.equal]
    [@printer fun fmt v -> Format.pp_print_string fmt (Yojson.Safe.to_string v)]);
}
[@@deriving eq, show]

type tool_result_content = {
  tool_call_id : string;
  content :
    (Yojson.Safe.t
    [@equal Yojson.Safe.equal]
    [@printer fun fmt v -> Format.pp_print_string fmt (Yojson.Safe.to_string v)]);
  is_error : bool;
}
[@@deriving eq, show]

type user_message = { role : string; content : user_content list }
[@@deriving eq, show]

type stop_reason =
  | EndTurn
  | ToolUse
  | MaxTokens
  | StopSequence
  | Error
  | Aborted
[@@deriving eq, show]

type usage = {
  input_tokens : int;
  output_tokens : int;
  cache_read_tokens : int;
  cache_write_tokens : int;
  cost_usd :
    (Decimal.t option
    [@equal fun a b -> Option.equal (fun x y -> Decimal.compare x y = 0) a b]
    [@printer fun fmt v -> Option.pp Decimal.pp fmt v]);
}
[@@deriving eq, show]

type provenance = {
  api : string;
  provider : string;
  model : string;
  error_message : string option;
}
[@@deriving eq, show]

type assistant_message = {
  content : assistant_content list;
  stop_reason : stop_reason;
  provenance : provenance;
  usage : usage;
}
[@@deriving eq, show]

type assistant_message_event =
  | AME_text_start of { partial : assistant_message }
  | AME_text_delta of { text : string; partial : assistant_message }
  | AME_thinking_start of { partial : assistant_message }
  | AME_thinking_delta of { text : string; partial : assistant_message }
  | AME_tool_call_start of {
      index : int;
      id : string;
      name : string;
      partial : assistant_message;
    }
  | AME_tool_call_delta of {
      index : int;
      arguments_fragment : string;
      partial : assistant_message;
    }
  | AME_tool_call_end of { index : int; partial : assistant_message }
  | AME_done of { message : assistant_message }
  | AME_error of { message : string; partial : assistant_message }
[@@deriving eq, show]

type file_error_code =
  | NotFound
  | PermissionDenied
  | Timeout
  | Aborted
  | Unknown
[@@deriving eq, show]

type file_error = { code : file_error_code; path : string; message : string }
[@@deriving eq, show]

type execution_error_code = Timeout | Aborted | NonZeroExit | Unknown
[@@deriving eq, show]

type execution_error = { code : execution_error_code; message : string }
[@@deriving eq, show]

type tool_error = { message : string; is_user_error : bool }
[@@deriving eq, show]

type model = { id : string; api : string; context_window : int }
[@@deriving eq, show]
