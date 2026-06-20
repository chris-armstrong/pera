(** Helpers for the conversation_driver binary.

    Provides mock tools, event description, scenario runners, and scenario
    functions used by [Conversation_driver]. *)

open Pera_core
open Pera_types

(** {1 Mock tools} *)

val echo_tool : unit Agent_types.tool
(** Echo the [text] argument back. Mode: Parallel. *)

val counter_tool : unit Agent_types.tool
(** Return an incrementing integer as a string. Mode: Sequential. *)

(** {1 Event description} *)

val describe_provider_event : Types.assistant_message_event -> string
(** Format a provider-level [assistant_message_event] as a one-liner. *)

val describe_agent_event : Agent_types.agent_event -> string
(** Format an [agent_event] as a one-liner for driver output. *)

(** {1 Loop configuration} *)

val make_config :
  ?tools:unit Agent_types.tool list ->
  ?get_follow_up_messages:(unit -> Agent_types.agent_message list) option ->
  model:Types.model ->
  Agent_types.stream_fn ->
  unit Agent_loop.agent_loop_config
(** Build a minimal [agent_loop_config] with the given model and stream_fn.
    Optional overrides for tools and follow-up messages. *)

(** {1 Scenario runner} *)

val run_scenario :
  name:string ->
  messages:Agent_types.agent_message list ->
  sw:Eio.Switch.t ->
  check_result:
    (Agent_types.agent_event list -> Agent_types.agent_message list -> bool) ->
  unit Agent_loop.agent_loop_config ->
  bool
(** Run a named scenario, printing each event, and return whether [check_result]
    passes. *)

(** {1 Scenarios} *)

val scenario_simple_text :
  model:Types.model -> Agent_types.stream_fn -> Eio.Switch.t -> bool

val scenario_echo_tool :
  model:Types.model -> Agent_types.stream_fn -> Eio.Switch.t -> bool

val scenario_multi_turn :
  model:Types.model -> Agent_types.stream_fn -> Eio.Switch.t -> bool

val scenario_parallel_echo :
  model:Types.model -> Agent_types.stream_fn -> Eio.Switch.t -> bool

(** {1 Entry helpers} *)

type scenario_result = { name : string; passed : bool }

val run_all_scenarios :
  model:Types.model ->
  Agent_types.stream_fn ->
  Eio.Switch.t ->
  scenario_result list

val run_named_scenario :
  string ->
  model:Types.model ->
  Agent_types.stream_fn ->
  Eio.Switch.t ->
  scenario_result list
