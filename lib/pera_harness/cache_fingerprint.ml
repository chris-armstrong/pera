open Containers

let src =
  Logs.Src.create "pera.cache_fingerprint" ~doc:"Cache prefix fingerprint"

module Log = (val Logs.src_log src : Logs.LOG)

type t = { combined : string; tools : string; system : string }

(** Render a tool to the same canonical JSON shape the Anthropic provider emits
    on the wire. Keys are alphabetical so the bytes are stable regardless of how
    the {!Pera_provider.Json_schema.t} was constructed. *)
let tool_to_canonical_json tool =
  `Assoc
    [
      ("description", `String (Pera_core.Agent_types.Tool.description tool));
      ( "input_schema",
        Pera_provider.Json_schema.to_json
          (Pera_core.Agent_types.Tool.schema tool) );
      ("name", `String (Pera_core.Agent_types.Tool.name tool));
    ]

let string_of_tool tool = Yojson.Safe.to_string (tool_to_canonical_json tool)

let compute ~system ~tools =
  let tools_bytes = List.map string_of_tool tools |> String.concat "" in
  let tools_digest = Digest.string tools_bytes in
  let system_digest = Digest.string system in
  let combined_digest = Digest.string (tools_digest ^ system_digest) in
  { combined = combined_digest; tools = tools_digest; system = system_digest }

let equal a b = String.equal a.combined b.combined

let pp ppf t =
  Format.fprintf ppf "Cache_fingerprint(%s)" (Digest.to_hex t.combined)

let check_and_warn ~previous ~current ~cache_policy =
  match cache_policy with
  | Pera_types.Types.No_cache -> ()
  | Pera_types.Types.Conversation | Pera_types.Types.SystemAndToolsOnly ->
      if not (equal previous current) then
        let tools_changed = not (String.equal previous.tools current.tools) in
        let system_changed =
          not (String.equal previous.system current.system)
        in
        let hint =
          match (tools_changed, system_changed) with
          | true, true -> "tools and system prompt differ"
          | true, false -> "tools differ"
          | false, true -> "system prompt differs"
          | false, false -> "prefix changed"
        in
        Log.warn (fun k ->
            k
              "[cache] prefix changed since last turn; previous cache writes \
               invalidated (%s)"
              hint)
