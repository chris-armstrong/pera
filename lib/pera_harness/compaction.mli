(** Compaction module — pure summarisation algorithm.

    Compacts a conversation's message history by summarising the middle portion
    with an LLM call, replacing it with a {!Pera_core.Agent_types.Synthetic}
    [Compaction_summary] message.

    This module is deliberately free of harness state, {!Session_writer}, and
    {!Agent_harness}. It takes a [stream_fn] and a message list in, and gives a
    new message list and summary out. The [compaction_driver] exercises exactly
    this surface. *)

type compaction_result = {
  new_messages : Pera_core.Agent_types.agent_message list;
      (** [[first] @ [Synthetic (Compaction_summary {summary})] @ tail]. *)
  summary : string;  (** The text produced by the summarisation call. *)
}
(** The output of a successful compaction. *)

val summarise_prompt : string
(** The hardcoded compaction system prompt (spec §8).

    Instructs the model to produce a concise summary preserving task, file
    paths, decisions, and project understanding, while discarding superseded
    exploration and raw file contents. *)

val render_messages_to_text : Pera_provider.Provider.message list -> string
(** A plain-text transcript of [messages]: one block per message, role-labelled
    ([User:] / [Assistant:] / [Tool result:]), tool calls and results inlined as
    text.

    Avoids provider message-shape constraints (e.g. [ToolResultMessage] need not
    follow a [tool_use] block in the summarisation request). *)

val compact :
  stream_fn:Pera_core.Agent_types.stream_fn ->
  model:Pera_types.Types.model ->
  options:Pera_provider.Provider.simple_stream_options ->
  messages:Pera_core.Agent_types.agent_message list ->
  tail_size:int ->
  sw:Eio.Switch.t ->
  (compaction_result option, string) result
(** [compact ~stream_fn ~model ~options ~messages ~tail_size ~sw] compacts
    [messages].

    Returns:
    - [Ok (Some r)] on success; [r.new_messages] is the compacted history.
    - [Ok None] when [List.length messages <= tail_size + 1] (empty middle — the
      re-compaction guard; nothing to summarise).
    - [Error msg] when the summarisation call fails or yields empty text. *)
