open Containers [@@warning "-33"]
open Pera_types

type tool_schema = {
  name : string;
  description : string;
  schema :
    (Json_schema.t
    [@equal
      fun a b ->
        Yojson.Safe.equal (Json_schema.to_json a) (Json_schema.to_json b)]
    [@printer
      fun fmt v ->
        Format.pp_print_string fmt
          (Yojson.Safe.to_string (Json_schema.to_json v))]);
}
[@@deriving eq, show]

type message =
  | UserMessage of Types.user_message
  | AssistantMessage of Types.assistant_message
  | ToolResultMessage of Types.tool_result_content
[@@deriving eq, show]

type context = {
  system : string;
  messages : message list;
  tools : tool_schema list;
  thinking : bool;
}
[@@deriving eq, show]

type simple_stream_options = { max_tokens : int; temperature : float option }
[@@deriving eq, show]

module type S = sig
  type t

  val name : string
  val create : env:Eio_unix.Stdenv.base -> sw:Eio.Switch.t -> t

  val stream_simple :
    t ->
    model:Types.model ->
    context:context ->
    options:simple_stream_options ->
    sw:Eio.Switch.t ->
    (Types.assistant_message_event, Types.assistant_message) Event_stream.t
end
