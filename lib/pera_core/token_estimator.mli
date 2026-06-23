val estimate_text : string -> int
(** ceil(String.length / 3) — conservative (overestimates). *)

val estimate_message : Pera_provider.Provider.message -> int
(** Sum of estimate_text over every text-bearing part of the message, plus a
    fixed per-message overhead of 4 tokens. Renders: user UText; assistant AText
    \+ AThinking.text
    + AToolCall (name + Yojson.Safe.to_string arguments); tool_result content
      (Yojson.Safe.to_string). UImage contributes a flat 8-token placeholder. *)

val estimate_messages : Pera_provider.Provider.message list -> int
(** Sum of estimate_message. *)
