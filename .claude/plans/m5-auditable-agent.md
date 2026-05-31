# M5 — Auditable agent (session logging)

> **Plan ID:** `m5-auditable-agent` · **Source:** SPECIFICATION.md §6 (agent wrapper), §7 (harness), §11 (M5 milestone), §12 (session_driver + harness_driver).
>
> Milestone M5: M4 plus session logging. Every event the agent emits is durable to disk in the JSONL tree format. Adds the agent wrapper (subscription fan-out, single-flight, observable state), the session writer, entry ID generation, and the assembled harness. Introduces `session_driver` and `harness_driver`.
>
> _This is the human-readable rendering of `.claude/plans/m5-auditable-agent.json`. If they ever disagree, the JSON is the source of truth._

---

## Settled design decisions

| # | Decision | Why |
|---|----------|-----|
| 1 | **Package split: `pera_env` + `pera_harness` + `pera_agent`** | Split `Execution_env`/`Local_env` into a new minimal `pera_env`. `pera_tools` and `pera_harness` both depend on `pera_env`. `Agent_harness` lives in a new `pera_agent` that depends on `pera_harness` + `pera_tools`. No cycles, clean names, no external API breakage (still in development). |
| 2 | **`pera_harness` gains `pera_core`, `pera_provider`, `yojson`, `uuidm` deps** | `Agent_wrapper` needs `Agent_loop.agent_loop_config` and `Agent_types.agent_event` (from `pera_core`). `Session_types` needs `Provider.message` (from `pera_provider`). Heavyweight components belong in implementation packages; acceptable as-is. |
| 3 | **Entry IDs: Option A — Standard non-truncated UUIDv7 strings (36 characters)** | Use the full standard 36-character UUIDv7 string. This ensures robust, guaranteed uniqueness, eliminates duplicate collision risks/infinite loop conditions inherent to 8-character truncation, and provides built-in lexicographical time-ordering. Clock non-monotonicity is not a practical concern; document in code. |
| 4 | **`Session_writer.append_entry` uses `Eio.Path.with_open_out ~append:true` per entry** | Opens, writes, fsyncs, closes per entry. Fine at turn-boundary rates. Whole-disk failure handling deferred. |
| 5 | **All session writes from the event subscriber** | `AE_turn_end.tool_results` is already sorted by source index (spec requirement). Persistent write failures logged to stderr, agent continues. Disk failure handling deferred. |
| 6 | **User messages written by `Agent_harness.send` before `Agent_loop.run`** | Loop emits no event for initial messages. Error recording possible in future if needed. |
| 7 | **`Agent_wrapper` uses actor/mailbox pattern (Option 3)** | `create ~sw` forks a long-lived actor fibre. `send` enqueues a `Run` message and awaits a reply promise — blocks caller until run completes, but serialisation is via queue not mutex flag. Capacity-1 mailbox: one pending send while one runs. Actor uses `Fun.protect` to always resolve the reply promise, including on exception and cancellation. `send` has no `~sw` parameter; the actor uses the wrapper's switch for all `Agent_loop.run` calls. |
| 8 | **`Leaf` entry written at `AE_turn_end`** | Fires once per turn after all tool results are batched. Old leaf entries stay in file (append-only). |
| 9 | **`convert_to_llm` uses refutation pattern for `Synthetic`** | `type synthetic = |` is uninhabited in M5. `| Synthetic _ -> .` gives a compile error in M6 if `CompactionSummary` is added without updating this function. |
| 10 | **`Prompt_assembly` inlined in `Agent_harness`** | Single 10-line function; extract to its own module in M7 when skills loading is added. |

## Open questions

None outstanding. All design decisions resolved.

---

## Baseline

- **`dune build`:** passes · **`dune runtest`:** tests pass across existing test suites · **Known failures:** none.
- M4 (acting agent) is complete. Libraries: `pera_types`, `pera_provider`, `pera_core`, `pera_core_test_util`, `pera_harness`, `pera_tools`. Drivers: `provider_driver`, `loop_driver`, `conversation_driver`, `env_driver`, `tool_driver`.

### What already exists (do not re-implement)

| Module | Decision |
|--------|----------|
| `Execution_env.S`, `Local_env` | **Reuse** — `pera_harness` owns these |
| `Tools.default`, `Read_tool`, `Write_tool`, `Bash_tool`, `Grep_tool` | **Reuse** — `pera_tools` owns these |
| `Agent_loop.run`, `Agent_types` | **Reuse** — `pera_core` owns these |
| `Provider_adapter`, `Event_stream` | **Reuse** — used by `Agent_harness` to wire providers |
| `Faux_provider.stream_fn_of_scripts` | **Reuse** — `harness_driver` injects this as `stream_fn` |

---

## Stage map

| Epoch | Stage | Title | Creates | Modifies | Depends |
|:---:|:---:|------|:---:|:---:|:---:|
| 0 | 0 | `pera_harness` dep upgrade + `Entry_id` | 3 | 3 | — |
| 0 | 1 | `Session_types` — entry defs + JSON codec | 3 | 1 | 0 |
| 1 | 2 | `Session_writer` — JSONL + fsync | 3 | 1 | 1 |
| 1 | 3 | `Agent_wrapper` — subscription + single-flight | 3 | 1 | 0 |
| 2 | 4 | `Agent_harness` — assembled harness in `pera_tools` | 3 | 2 | 2, 3 |
| 3 | 5 | `session_driver` | 1 | 1 | 2 |
| 3 | 6 | `harness_driver` | 1 | 1 | 4 |

**7 stages across 4 epochs.** Estimated touch: 17 new files, 10 modified.

---

## Epoch 0 — Entry ID + Session types

### Stage 0 — `pera_harness` dep upgrade + `Entry_id` + HTTP connect timeout + Decimal support

Lifts `pera_harness`'s dependency list to include `pera_core`, `pera_provider`, `yojson`, and `uuidm`. Introduces `Entry_id` — the module responsible for generating standard 36-character UUIDv7-based identifiers. Adds `decimal` to types and provides a 5s connection timeout configuration in the HTTP client to avoid test hangs on DROP firewalls.

**Creates:**
- `lib/pera_harness/entry_id.mli`
- `lib/pera_harness/entry_id.ml`
- `lib/pera_harness/test/entry_id_test.ml`
- `lib/pera_env/test/local_env_fs_test.ml` (moved from harness)
- `lib/pera_env/test/local_env_sh_test.ml` (moved from harness)

**Modifies:**
- `lib/pera_harness/dune` — new modules list, new library deps
- `dune-project` — `pera-harness` opam package gains `pera-core`, `pera-provider`, `yojson`, `uuidm` deps; `pera-types` package gains `decimal` dependency
- `lib/pera_harness/test/dune` — add `entry_id_test` to stanza, remove moved tests
- `lib/pera_provider/http_client.ml` — configure Piaf client with a 5-second `connect_timeout`
- `lib/pera_types/types.mli` & `lib/pera_types/types.ml` — update `cost_usd` from `float option` to `Decimal.t option`

#### Updated `lib/pera_harness/dune`

```
(library
 (name pera_harness)
 (public_name pera-harness)
 (modules execution_env local_env entry_id session_types session_writer agent_wrapper)
 (libraries pera_types pera_provider pera_core eio eio_main eio_linux unix
            containers fpath yojson uuidm)
 (preprocess
  (pps ppx_deriving.eq ppx_deriving.show)))
```

Note: `session_types`, `session_writer`, and `agent_wrapper` are listed here even though they are created in later stages — dune will fail to build until those files exist. Add the new modules one stage at a time, or stub them immediately with empty `.mli`/`.ml` files.

#### `Entry_id` interface

```ocaml
(* entry_id.mli *)

type t = string
(** A standard 36-character UUIDv7 identifier. *)

val generate : unit -> t
(** [generate ()] allocates a fresh entry ID using the current wall clock. The
    full standard 36-character UUIDv7 string (RFC 9562) is returned. 
    Lexicographic order of IDs matches creation order across processes. *)

val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
val show : t -> string
```

#### `Entry_id` implementation notes

Use `Uuidm.v7_non_monotonic_gen` to build a generator once at module initialisation:

```ocaml
open Containers

let rand_state = Random.State.make_self_init ()

let gen =
  Uuidm.v7_non_monotonic_gen
    ~now_ms:(fun () -> Int64.of_float (Unix.gettimeofday () *. 1000.))
    rand_state

let generate () =
  let uuid = gen () in
  Uuidm.to_string uuid
```

`Uuidm.v7_non_monotonic_gen` signature: `now_ms:posix_ms_clock -> Random.State.t -> (unit -> Uuidm.t)` where `posix_ms_clock = unit -> int64`. The returned function is called once per `generate ()` invocation.

**Do not use `Uuidm.v7_monotonic_gen`**: it returns `unit -> t option` (returns `None` on counter rollover). The non-monotonic variant is sufficient for M5's collision rates.

#### Tests for `Entry_id`

| Test | Scenario | Asserts |
|------|----------|---------|
| `test_generate_returns_36_chars` | Single call | Length = 36 |
| `test_generate_returns_lowercase_hex_and_hyphens` | Single call | Matches standard UUID regex `^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$` |
| `test_generate_ids_are_unique` | 1000 calls | All distinct |
| `test_generate_ids_are_lexicographically_ordered_over_time` | 10 calls with 2ms sleep between each | Each id >= previous (string comparison) |

For `test_generate_ids_are_lexicographically_ordered_over_time`: sleep using `Unix.sleepf 0.002` between calls. This exercises the timestamp ordering property. Note: the test is sensitive to clock resolution; it is sufficient to assert that *most* ids are ordered (allow 1 inversion due to clock skew), or use a sleep long enough for reliable ordering.

---

### Stage 1 — `Session_types` — entry definitions + JSON codec

Defines all session entry types and their JSONL serialisation. Provides `entry_to_json` for writing and the types needed for `Session_writer` and `Agent_harness`.

**Creates:**
- `lib/pera_harness/session_types.mli`
- `lib/pera_harness/session_types.ml`
- `lib/pera_harness/test/session_types_test.ml`

**Modifies:**
- `lib/pera_harness/test/dune` — add `session_types_test`

#### Session entry types

```ocaml
(* session_types.mli *)

open Pera_types

type entry_id = Entry_id.t
(** Alias for readability. *)

(** {1 Entry types} *)

type session_info_entry = {
  id : entry_id;
  timestamp : float;
  session_id : string;
  cwd : string;
  model : Types.model;
  parent_session_id : string option;
      (** Included for forward-compatibility (§13 item 10). Always [None] in M5. *)
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
  model : Types.model;
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
(** Stub type for M6. Not written in M5; included so the codec is forward-compatible. *)

type session_entry =
  | SessionInfo of session_info_entry
  | Message of message_entry
  | Leaf of leaf_entry
  | ModelChange of model_change_entry
  | ThinkingLevelChange of thinking_level_change_entry
  | Compaction of compaction_entry

(** {1 Serialisation} *)

val entry_to_json : session_entry -> Yojson.Safe.t
(** [entry_to_json e] serialises [e] to a JSON object suitable for writing
    as a JSONL line. Every variant includes ["id"], ["type"], ["timestamp"].
    Variants with parent context include ["parent_id"] when not [None]. *)

val message_to_json : Pera_provider.Provider.message -> Yojson.Safe.t
(** [message_to_json msg] serialises a provider message to its JSON representation
    for embedding inside a [Message] entry. *)
```

#### JSONL format — examples

Each line is the output of `Yojson.Safe.to_string (entry_to_json e)` followed by `\n`.

```jsonl
{"id":"1a2b3c4d","type":"session_info","timestamp":1748739600.123,"session_id":"e5f6a7b8","cwd":"/home/user/project","model":{"id":"claude-sonnet-4-6","api":"anthropic"}}
{"id":"2b3c4d5e","parent_id":"1a2b3c4d","type":"message","timestamp":1748739601.0,"message":{"role":"user","content":[{"type":"text","text":"Hello"}]}}
{"id":"3c4d5e6f","parent_id":"2b3c4d5e","type":"message","timestamp":1748739602.0,"message":{"role":"assistant","content":[{"type":"text","text":"Hi there!"}],"stop_reason":"end_turn","provenance":{"api":"anthropic","provider":"Anthropic","model":"claude-sonnet-4-6"},"usage":{"input_tokens":10,"output_tokens":5,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":"0.00015"}}}
{"id":"4d5e6f7a","parent_id":"3c4d5e6f","type":"leaf","timestamp":1748739602.1}
```

#### `message_to_json` specification

Manually written JSON codec for `Provider.message`. No ppx. All fields use snake_case string keys.

**`UserMessage { role; content }`:**
```json
{"role": "user", "content": [<content_block>, ...]}
```
`UText t` → `{"type":"text","text":"..."}` · `UImage { url; media_type }` → `{"type":"image","url":"...","media_type":"..."}`

**`AssistantMessage { content; stop_reason; provenance; usage }`:**
```json
{
  "role": "assistant",
  "content": [<content_block>, ...],
  "stop_reason": "end_turn",
  "provenance": {"api":"...","provider":"...","model":"..."},
  "usage": {"input_tokens":N,"output_tokens":N,"cache_read_tokens":N,"cache_write_tokens":N,"cost_usd":<string|null>}
}
```
`AText t` → `{"type":"text","text":"..."}` · `AThinking { text; signature }` → `{"type":"thinking","text":"...","signature":<string|null>}` · `AToolCall { id; name; arguments }` → `{"type":"tool_call","id":"...","name":"...","arguments":<json>}`

`stop_reason` string values: `EndTurn→"end_turn"`, `ToolUse→"tool_use"`, `MaxTokens→"max_tokens"`, `StopSequence→"stop_sequence"`, `Error→"error"`, `Aborted→"aborted"`

`provenance.error_message` is omitted when `None` (not `null`).

**`ToolResultMessage { tool_call_id; content; is_error }`:**
```json
{"role":"tool_result","tool_call_id":"...","content":<json>,"is_error":false}
```

#### Tests for `Session_types`

All tests are pure (no IO, no Eio).

| Test | Asserts |
|------|---------|
| `test_session_info_entry_serialises_required_fields` | JSON has `id`, `type:"session_info"`, `timestamp`, `session_id`, `cwd`, `model` |
| `test_session_info_entry_omits_parent_session_id_when_none` | `parent_session_id=None` → no `"parent_session_id"` key in JSON |
| `test_message_entry_serialises_parent_id` | `parent_id=Some "abc12345"` → JSON has `"parent_id":"abc12345"` |
| `test_message_entry_omits_parent_id_when_none` | `parent_id=None` → no `"parent_id"` key |
| `test_leaf_entry_serialises_correctly` | `type:"leaf"` present |
| `test_user_message_content_serialised_as_array` | `UserMessage([UText "hi"])` → `{"role":"user","content":[{"type":"text","text":"hi"}]}` |
| `test_assistant_message_stop_reason_strings` | Each `stop_reason` variant → correct string value |
| `test_assistant_thinking_block_serialised` | `AThinking{text="t";signature=Some "s"}` → `{"type":"thinking","text":"t","signature":"s"}` |
| `test_tool_call_arguments_embedded_as_json` | `AToolCall{arguments=\`Assoc[("k",\`String "v")]}` → `"arguments":{"k":"v"}` |
| `test_tool_result_message_serialised` | `ToolResultMessage{is_error=true;...}` → `"is_error":true` |
| `test_assistant_message_cost_usd_serialised` | `cost_usd=Some (Decimal.of_string "0.0015")` → `"cost_usd":"0.0015"` in usage |
| `test_entry_to_json_wraps_message_entry` | Full `Message` entry → outer has `id/type/timestamp/parent_id/message` keys |

---

## Epoch 1 — Session writer + Agent wrapper

### Stage 2 — `Session_writer` — JSONL + fsync

Append-only JSONL file writer. Each `append_entry` writes one JSON line, calls `Eio.File.sync`, and returns before the next call. Manages a `current_parent_id` chain internally so callers do not need to track parentage.

**Creates:**
- `lib/pera_harness/session_writer.mli`
- `lib/pera_harness/session_writer.ml`
- `lib/pera_harness/test/session_writer_test.ml`

**Modifies:**
- `lib/pera_harness/test/dune` — add `session_writer_test`

#### Interface

```ocaml
(* session_writer.mli *)

type t
(** An open session writer. Owns the current-parent-ID chain; not thread-safe — call
    from a single fibre. *)

val create :
  path:string ->
  env:Eio_unix.Stdenv.base ->
  model:Pera_types.Types.model ->
  cwd:string ->
  (t, Pera_types.Types.file_error) result
(** [create ~path ~env ~model ~cwd] initialises a new session. Creates parent
    directories if needed. Allocates a [session_id] via [Entry_id.generate].

    Does NOT write the [SessionInfo] entry — the caller writes it via
    [write_session_info] as its first call. Separating creation from writing
    allows the caller to set up the writer and then write the header entry as
    part of a controlled sequence. *)

val write_session_info : t -> (unit, Pera_types.Types.file_error) result
(** Writes the [SessionInfo] entry with the session metadata from [create].
    Must be called exactly once, as the first write after [create]. Sets the
    [current_parent_id] to the [SessionInfo] entry's ID. *)

val write_message :
  t ->
  Pera_provider.Provider.message ->
  (unit, Pera_types.Types.file_error) result
(** [write_message t msg] writes a [Message] entry with parent = [current_parent_id].
    Updates [current_parent_id] to the new entry's ID. *)

val write_leaf : t -> (unit, Pera_types.Types.file_error) result
(** Writes a [Leaf] entry with parent = [current_parent_id].
    Updates [current_parent_id] to the new leaf entry's ID. *)

val write_model_change :
  t ->
  Pera_types.Types.model ->
  (unit, Pera_types.Types.file_error) result
(** Writes a [ModelChange] entry. *)

val session_id : t -> string
(** Returns the session's unique identifier. *)

val current_parent_id : t -> Entry_id.t option
(** Returns the current parent ID for inspection (testing). *)
```

#### Implementation — `append_line`

```ocaml
open Containers

type t = {
  path : string;
  base : Eio.Fs.dir_ty Eio.Path.t;
  session_id : string;
  model : Pera_types.Types.model;
  cwd : string;
  mutable current_parent_id : Entry_id.t option;
}

let catch_write path fn =
  try Ok (fn ()) with
  | Eio.Io (Eio.Fs.E (Not_found _), _) ->
      Error Pera_types.Types.{ code = NotFound; path; message = "not found" }
  | Eio.Io (_, _) as exn ->
      Error Pera_types.Types.{ code = Unknown; path; message = Printexc.to_string exn }
  | exn ->
      Error Pera_types.Types.{ code = Unknown; path; message = Printexc.to_string exn }

let append_line t json =
  catch_write t.path (fun () ->
    let line = Yojson.Safe.to_string json ^ "\n" in
    Eio.Path.with_open_out ~append:true ~create:(`If_missing 0o644)
      Eio.Path.(t.base / t.path)
      (fun file ->
        Eio.Flow.copy_string line file;
        Eio.File.sync file))
```

`Eio.Path.with_open_out` does not require a `~sw` argument — it opens, runs the callback, then closes. `Eio.File.sync` takes `_ Eio.File.rw` — the file handle returned by `with_open_out` satisfies this constraint since `Eio.Path.open_out` returns `Eio.File.rw_ty Eio.Resource.t` and `rw_ty = [ro_ty | Flow.sink_ty]`.

`Eio.Flow.copy_string : string -> _ #Flow.sink -> unit`. The file handle from `with_open_out` has type `Eio.File.rw_ty Eio.Resource.t` which satisfies `#Flow.sink` via `rw_ty`'s inclusion of `Flow.sink_ty`.

#### `create` — directory creation

```ocaml
let create ~path ~env ~model ~cwd =
  let base = env#fs in
  let parent = Filename.dirname path in
  (try Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 Eio.Path.(base / parent)
   with _ -> ());
  let session_id = Entry_id.generate () in
  Ok { path; base; session_id; model; cwd; current_parent_id = None }
```

#### Tests for `Session_writer`

Tests run under `Eio_main.run` with a temp directory.

| Test | Asserts |
|------|---------|
| `test_write_session_info_creates_file_with_valid_jsonl` | File exists; first line parses as JSON with `type:"session_info"` |
| `test_write_message_appends_line_with_parent_id` | After `write_session_info` + `write_message`, second line's `parent_id` = first line's `id` |
| `test_write_leaf_sets_parent_to_last_message` | Leaf `parent_id` = last `Message` id |
| `test_parent_chain_forms_linked_list` | Three entries: session_info → message → leaf; parent chain is correct |
| `test_append_is_durable_each_write` | Write entry, truncate process (simulate with `Sys.command "kill -9"`) — this is a manual test only; the automated version verifies that `Eio.File.sync` is called (via a mock, or via checking file contents without `close`) |
| `test_create_makes_parent_directories` | `path="a/b/c/session.jsonl"` under temp dir; `create` succeeds; directories `a/b/c` exist |
| `test_session_id_is_uuid` | `session_id t` is a valid standard 36-character UUIDv7 |

---

### Stage 3 — `Agent_wrapper` — subscription + single-flight + observable state

A thin layer over `Agent_loop.run` providing subscription fan-out, single-flight enforcement, and observable state.

**Creates:**
- `lib/pera_harness/agent_wrapper.mli`
- `lib/pera_harness/agent_wrapper.ml`
- `lib/pera_harness/test/agent_wrapper_test.ml`

**Modifies:**
- `lib/pera_harness/test/dune` — add `agent_wrapper_test`; add `pera_core_test_util` to deps

#### Interface

```ocaml
(* agent_wrapper.mli *)

type 'ctx t
(** A wrapper around an agent loop run. Parameterised by the tool context
    type ['ctx]. Not thread-safe across [send] calls; concurrent [send] is
    rejected. *)

val create : config:'ctx Pera_core.Agent_loop.agent_loop_config -> sw:Eio.Switch.t -> 'ctx t
(** [create ~config ~sw] constructs a wrapper and forks a background actor fiber. *)

val subscribe :
  'ctx t -> (Pera_core.Agent_types.agent_event -> unit) -> (unit -> unit)
(** [subscribe t f] registers [f] as an event subscriber. Returns an
    unsubscribe function. Subscribers are called in registration order from
    within [send], in the same fibre. Subscriber exceptions propagate out of
    [send].

    Safe to call while [send] is not running. Calling during a [send] is
    unspecified behaviour (M5: not required). *)

val send :
  'ctx t ->
  messages:Pera_core.Agent_types.agent_message list ->
  unit
(** [send t ~messages] runs the agent with [messages] as initial history.
    Blocks until the run completes (all events consumed, stream closed).
    Raises [Failure "Agent_wrapper: concurrent send attempted"] if already
    running.

    All subscribers are called for every event, in registration order. The
    final [AE_agent_end] event updates [current_messages]. *)

val is_streaming : 'ctx t -> bool
(** [is_streaming t] is [true] while [send] is running. *)

val pending_tool_call_names : 'ctx t -> string list
(** [pending_tool_call_names t] returns the names of tool calls currently
    in-flight (between [AE_tool_execution_start] and [AE_tool_execution_end]). *)

val current_messages : 'ctx t -> Pera_core.Agent_types.agent_message list
(** [current_messages t] returns the conversation history after the last
    completed [send], or [[]] before the first [send]. *)
```

#### Implementation notes

```ocaml
type msg =
  | Run of {
      messages : Pera_core.Agent_types.agent_message list;
      reply : unit Eio.Promise.u;
    }

type 'ctx t = {
  config : 'ctx Pera_core.Agent_loop.agent_loop_config;
  mailbox : msg Eio.Stream.t; (* capacity 1 *)
  mutable subscribers : (Pera_core.Agent_types.agent_event -> unit) list;
  mutable is_running : bool;
  mutable in_flight_tools : string list;
  mutable messages : Pera_core.Agent_types.agent_message list;
  sub_mutex : Eio.Mutex.t;
}
```

`create` and actor loop implementation:

```ocaml
let create ~config ~sw =
  let t = {
    config;
    mailbox = Eio.Stream.create 1;
    subscribers = [];
    is_running = false;
    in_flight_tools = [];
    messages = [];
    sub_mutex = Eio.Mutex.create ();
  } in
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      let (Run { messages; reply }) = Eio.Stream.take t.mailbox in
      t.is_running <- true;
      Fun.protect
        ~finally:(fun () ->
          t.is_running <- false;
          t.in_flight_tools <- [];
          Eio.Cancel.protect (fun () -> Eio.Promise.resolve reply ()))
        (fun () ->
          let stream = Pera_core.Agent_loop.run t.config ~messages ~sw in
          Pera_provider.Event_stream.iter stream ~f:(fun event ->
            update_state t event;
            let subs = Eio.Mutex.use_ro t.sub_mutex (fun () -> t.subscribers) in
            List.iter (fun sub -> sub event) subs));
      loop ()
    in
    loop ());
  t
```

`send` implementation:

```ocaml
let send t ~messages =
  let p, u = Eio.Promise.create () in
  (match Eio.Stream.add ~timeout:0.0 t.mailbox (Run { messages; reply = u }) with
  | () -> ()
  | exception Eio.Stream.Full -> failwith "Agent_wrapper: concurrent send attempted");
  Eio.Promise.await p
```

`update_state t event` updates `in_flight_tools` and `messages` from the event:
- `AE_tool_execution_start { tool_name }` → `in_flight_tools := tool_name :: t.in_flight_tools`
- `AE_tool_execution_end { tool_name }` → `in_flight_tools := List.remove_first ~eq:String.equal tool_name t.in_flight_tools`
- `AE_agent_end { messages }` → `t.messages <- messages`

`subscribe` returns an unsubscribe function using a ref to the subscriber function, filtered out on unsubscribe:

```ocaml
let subscribe t f =
  Eio.Mutex.use_rw t.sub_mutex (fun () ->
    t.subscribers <- t.subscribers @ [f]);
  (fun () ->
    Eio.Mutex.use_rw t.sub_mutex (fun () ->
      t.subscribers <- List.filter (fun sub -> not (phys_equal sub f)) t.subscribers))
```

`phys_equal` is `(==)` (physical equality) from Containers. This is correct for function values.

#### Tests for `Agent_wrapper`

Tests use `Faux_provider.stream_fn_of_scripts` and `Eio_main.run`.

| Test | Asserts |
|------|---------|
| `test_subscriber_receives_all_events` | Subscribe f; send with 1-turn script; f called for each event in correct order |
| `test_multiple_subscribers_all_notified` | Two subscribers; both receive every event |
| `test_unsubscribe_stops_notifications` | Subscribe f, get unsub; unsub (); send; f not called |
| `test_concurrent_send_raises` | Fork two fibres calling `send` simultaneously; one raises `Failure "Agent_wrapper: concurrent send attempted"` |
| `test_is_streaming_true_during_send` | Check `is_streaming` from within a subscriber; true during send |
| `test_is_streaming_false_before_and_after_send` | Before send: false; after send: false |
| `test_pending_tool_calls_updated_during_execution` | Script with tool call; subscriber at `AE_tool_execution_start` sees tool name in `pending_tool_call_names` |
| `test_current_messages_updated_after_send` | After send: `current_messages` = final message list from `AE_agent_end` |
| `test_current_messages_empty_before_first_send` | Before send: `current_messages = []` |

---

## Epoch 2 — Assembled harness

### Stage 4 — `Agent_harness` — assembled harness in `pera_agent`

Binds `Local_env`, `Tools.default`, `Session_writer`, and `Agent_wrapper` into a single entry point. Provides `send` (writes user message + runs agent) and `subscribe`.

**Creates:**
- `lib/pera_agent/agent_harness.mli`
- `lib/pera_agent/agent_harness.ml`
- `lib/pera_agent/test/agent_harness_test.ml`
- `lib/pera_agent/test/dune`

**Modifies:**
- `lib/pera_agent/dune` — populate modules list, library deps (including `pera_harness`, `pera_tools`, `pera_env`, `pera_core`, `pera_provider`, `pera_types`, `eio`, `eio_main`, `eio_linux`, `containers`, `yojson`)
- `dune-project` — ensure `pera-agent` package dependencies are correctly updated

#### Interface

```ocaml
(* agent_harness.mli *)

type t
(** Assembled agent harness. Owns the execution environment, tool list, session
    writer, and agent wrapper. *)

type config = {
  cwd : string;
      (** Working directory for filesystem and shell operations. *)
  model : Pera_types.Types.model;
      (** The model used for LLM calls. *)
  session_path : string;
      (** Absolute path to the JSONL session log file. *)
  stream_fn : Pera_core.Agent_types.stream_fn;
      (** Provider stream function. Inject [Faux_provider.stream_fn_of_scripts]
          in tests; use [Provider_adapter.stream_fn adapter] in production. *)
  max_tokens : int;
      (** Maximum tokens per LLM call. *)
}
(** Configuration for [create]. *)

val create :
  config:config ->
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  (t, Pera_types.Types.file_error) result
(** [create ~config ~env ~sw] creates the harness, initializing the underlying
    [Agent_wrapper] with [sw]. Creates the session file's
    parent directories. Does NOT write the [SessionInfo] entry yet — that
    happens on the first [send]. *)

val send :
  t ->
  string ->
  unit
(** [send t text] adds [text] as a user message, writes it to the session
    log, and runs the agent loop via the wrapper's background actor fiber.
    Blocks until the run completes. *)

val subscribe :
  t ->
  (Pera_core.Agent_types.agent_event -> unit) ->
  (unit -> unit)
(** [subscribe t f] registers an event subscriber; returns an unsubscribe
    function. Delegates to the underlying [Agent_wrapper]. *)
```

#### Internal wiring

```ocaml
let build_system_prompt tools =
  let base = "You are a helpful coding assistant. Work methodically, \
              verify your understanding before acting, and prefer small \
              targeted changes." in
  let descs = List.map (fun (t : unit Pera_core.Agent_types.tool) ->
    Printf.sprintf "- %s: %s" t.name t.description) tools in
  if List.is_empty descs then base
  else base ^ "\n\nAvailable tools:\n" ^ String.concat "\n" descs

let convert_to_llm messages =
  List.filter_map (function
    | Pera_core.Agent_types.Real msg -> Some msg
    | Pera_core.Agent_types.Synthetic _ -> .) messages
```

Note: `| Pera_core.Agent_types.Synthetic _ -> .` uses OCaml refutation syntax — the `Synthetic` constructor has uninhabited payload `type synthetic = |`, so the arm is unreachable. This will need updating in M6 when `CompactionSummary` is added.

The `agent_loop_config` built in `create`:

```ocaml
let config = Pera_core.Agent_loop.{
  model = config.model;
  system = build_system_prompt tools;
  options = Pera_provider.Provider.{ max_tokens = config.max_tokens; temperature = None };
  stream_fn = config.stream_fn;
  convert_to_llm;
  tool_ctx = ();
  tools;
  tool_execution = `Parallel;
  transform_context = None;
  get_api_key = None;
  before_tool_call = None;
  after_tool_call = None;
  should_stop_after_turn = None;
  prepare_next_turn = None;
  get_steering_messages = None;
  get_follow_up_messages = None;
}
```

The session writer subscriber (registered in `create`) observes events and writes entries:

```ocaml
let session_subscriber writer event =
  let open Result.Syntax in
  let result = match event with
    | Pera_core.Agent_types.AE_message_end { message = Real (AssistantMessage am) } ->
        Session_writer.write_message writer (Provider.AssistantMessage am)
    | AE_message_end _ -> Ok ()
    | AE_turn_end { tool_results; _ } ->
        let* () = List.fold_left (fun acc tr ->
          let* () = acc in
          Session_writer.write_message writer (Provider.ToolResultMessage tr))
          (Ok ()) tool_results in
        Session_writer.write_leaf writer
    | _ -> Ok ()
  in
  match result with
  | Ok () -> ()
  | Error e ->
      Printf.eprintf "session write error: %s\n%!" e.Pera_types.Types.message
```

The initial `SessionInfo` and user `Message` entries are written in `send`:

```ocaml
let send t text =
  (* Write SessionInfo on first send *)
  if not t.session_info_written then (
    (match Session_writer.write_session_info t.writer with
    | Ok () -> ()
    | Error e -> Printf.eprintf "session_info write error: %s\n%!" e.message);
    t.session_info_written <- true);
  (* Write user message entry *)
  let um = Pera_provider.Provider.UserMessage
    Pera_types.Types.{ role = "user"; content = [ UText text ] } in
  (match Session_writer.write_message t.writer um with
  | Ok () -> ()
  | Error e -> Printf.eprintf "user message write error: %s\n%!" e.message);
  (* Build agent message and run *)
  let agent_msg = Pera_core.Agent_types.Real um in
  let history = t.wrapper |> Agent_wrapper.current_messages in
  let messages = history @ [ agent_msg ] in
  Agent_wrapper.send t.wrapper ~messages
```

#### Tests for `Agent_harness`

Tests use `Faux_provider.stream_fn_of_scripts` and a temp directory.

| Test | Asserts |
|------|---------|
| `test_send_creates_session_file` | After `send`, session file exists at configured path |
| `test_session_file_contains_session_info_on_first_send` | First line: `type:"session_info"` |
| `test_session_file_contains_user_message` | Second line: `type:"message"`, `role:"user"`, `text` matches input |
| `test_session_file_contains_assistant_message` | Line for assistant: `role:"assistant"` |
| `test_session_file_ends_with_leaf` | Last line: `type:"leaf"` |
| `test_parent_chain_is_contiguous` | Parse all lines; each `parent_id` = previous line's `id` |
| `test_second_send_continues_parent_chain` | Two sends; no gaps in parent chain across turns |
| `test_subscriber_receives_events` | Register subscriber; `send`; subscriber called with expected events |

---

## Epoch 3 — Drivers

### Stage 5 — `session_driver`

Directly exercises `Session_writer` in isolation. Appends a representative sequence of entries and verifies the JSONL output. Does not involve the agent loop.

**Creates:** `bin/drivers/session_driver.ml`

**Modifies:** `bin/drivers/dune` — add `session_driver` executable

#### Driver executable stanza

```
(executable
 (name session_driver)
 (libraries pera_harness pera_provider pera_types eio eio_main eio_linux
            containers yojson))
```

#### Scenarios (5)

| # | Scenario | What it appends | What it verifies |
|---|----------|-----------------|------------------|
| 1 | `header_then_leaf` | SessionInfo + Leaf | 2 lines; Leaf `parent_id` = SessionInfo `id` |
| 2 | `user_assistant_turn` | SessionInfo + UserMessage + AssistantMessage + Leaf | 4 lines; correct types; parent chain is linear |
| 3 | `tool_use_turn` | SessionInfo + UserMessage + AssistantMessage + ToolResultMessage + Leaf | 5 lines; all entries present |
| 4 | `two_turns` | SessionInfo + 2 user msgs + 2 assistant msgs + 2 leaves | 7 lines; second leaf's `parent_id` = second assistant's `id`; not first leaf |
| 5 | `model_change` | SessionInfo + ModelChange + UserMessage + AssistantMessage + Leaf | ModelChange entry has correct `model` field |

For each scenario: create `Session_writer`, call the relevant `write_*` functions, then read back the file with `Eio.Path.load`, parse each line with `Yojson.Safe.from_string`, and assert the expected structure.

Print `[session] <scenario_name> ... PASS/FAIL` per scenario. Exit 0 if all pass, 1 otherwise.

---

### Stage 6 — `harness_driver`

Exercises the full assembled harness (`Agent_harness`) against `Faux_provider`. Verifies that the session log reflects the events and the parent chain is well-formed.

**Creates:** `bin/drivers/harness_driver.ml`

**Modifies:** `bin/drivers/dune` — add `harness_driver` executable

#### Driver executable stanza

```
(executable
 (name harness_driver)
 (libraries pera_agent pera_tools pera_harness pera_core pera_core_test_util pera_provider
            pera_types eio eio_main eio_linux containers yojson))
```

#### Scenarios (3)

| # | Scenario | Script | What it verifies |
|---|----------|--------|-----------------|
| 1 | `text_only` | 1-turn Faux script: text reply, stop_reason=EndTurn | Session file: SessionInfo + UserMessage + AssistantMessage + Leaf (4 entries); parent chain linear |
| 2 | `tool_use` | 2-turn script: turn 1 produces 1 tool call; turn 2 produces text reply | Session file: SessionInfo + UserMessage + AssistantMessage + ToolResultMessage + Leaf + AssistantMessage + Leaf (7 entries); events emitted include `AE_tool_execution_start`, `AE_tool_execution_end` |
| 3 | `multi_turn_follow_up` | 3-turn script using `get_follow_up_messages`: three text replies | Session file has entries for all three turns; leaf always at end |

For each scenario:
1. Create a temp dir for the session file.
2. Build the Faux_provider script.
3. Create `Agent_harness`.
4. Optionally subscribe to collect events.
5. Call `Agent_harness.send`.
6. Read and parse the JSONL file.
7. Assert entry count, types, and parent chain.

Helper `parse_session_file path`: reads file, splits on newlines, filters empty lines, parses each line as `Yojson.Safe.t`, returns `Yojson.Safe.t list`.

Helper `check_parent_chain entries`: zips consecutive pairs, asserts `entries.(i).id = entries.(i+1).parent_id` for all `i > 0`.

Print `[harness] <scenario_name> ... PASS/FAIL`. Exit 0 if all pass, 1 otherwise.

---

## Key risks

| Risk | Mitigation |
|------|------------|
| `Eio.File.sync` type compatibility with `with_open_out` return type | `with_open_out` returns `File.rw_ty Resource.t`; `sync : _ rw -> unit` where `rw_ty = [ro_ty \| Flow.sink_ty]`. Should satisfy. Verify at Stage 2; if type mismatch, open with `Eio.Path.open_out ~sw` and close explicitly. |
| `Eio.Flow.copy_string` type compatibility with file handle | `copy_string : string -> _ #Flow.sink -> unit`. `File.rw_ty` includes `Flow.sink_ty`. Should satisfy. Same fallback as above. |
| `Synthetic` arm in `convert_to_llm` | Uses OCaml refutation syntax `| Synthetic _ -> .` — requires `Synthetic` to be uninhabited. `type synthetic = |` is uninhabited. This compiles in OCaml 5.x. Verify with `dune build`. |
| Session write errors silently swallowed in subscriber | The subscriber logs to stderr but does not abort the run. This matches the spec: "does not modify context.messages" on failure. For M5, write failures are logged; M6 can surface them as `compaction_error`-style events. |
| `phys_equal` for subscriber unsubscribe | `List.filter (not (phys_equal sub f))` works for function values stored as closures. Verify that `subscribe` captures the exact closure reference so `phys_equal` works as expected. |
| `pera_harness` circular dep risk | `pera_harness` adds `pera_core` as dep. `pera_tools` already depends on both. No cycle introduced. Verify dune dep graph after Stage 0. |

---

## What M5 does NOT include

- **No compaction** — M6. `Compaction` entry type is stubbed in `Session_types` but never written.
- **No session restore / replay** — read-back is deferred. `Session_writer` write side only.
- **No `edit` tool, skills, OAuth** — out of scope v1.
- **No streaming compaction, MCP, or branch summarisation** — out of scope.
- **`should_stop_after_turn` hook** — wired to `None` in M5. Compaction adds this in M6.
- **`get_follow_up_messages` in `Agent_harness.send`** — stub in M5 (no UI input loop). The `harness_driver` scenario 3 exercises it directly via `Faux_provider`.
