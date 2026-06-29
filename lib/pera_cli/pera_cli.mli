(** Reusable CLI wiring for Pera.

    The [Make] functor takes an [Env] module that describes the execution
    environment (OS process, stdin/stdout, filesystem) and produces [run] and
    [run_with] entry points. *)

(** The execution/process environment the CLI runs against.

    [ctx] is pinned to [(module Pera_env.Execution_env.S)] so that
    [Agent_harness.config.exec_env] accepts it directly. *)
module type Env = sig
  type ctx = (module Pera_env.Execution_env.S)

  val create : env:Eio_unix.Stdenv.base -> sw:Eio.Switch.t -> cwd:string -> ctx
  (** Create the execution context for the given working directory. *)

  val tools :
    ctx -> (module Pera_env.Execution_env.S) Pera_core.Agent_types.tool list
  (** Return the base tool list for this environment. *)

  val has_shell : bool
  (** [true] if this environment supports shell-backed tools. *)

  val getenv_opt : string -> string option
  (** Process-environment accessor, usable before [ctx] exists (config
      resolution happens before env creation). Injecting this makes
      [Env_reader] / [Config_resolver] / [Session_path] testable without
      [Unix.putenv] or real TTYs. *)

  val home : unit -> string
  val secure_random : env:Eio_unix.Stdenv.base -> bytes -> unit
  val stdin_isatty : env:Eio_unix.Stdenv.base -> bool
end

(** Re-exported for [run_with] callers. *)
module Resolved_inputs : sig
  type t = Config_resolver.resolve_inputs
end

module Make (_ : Env) : sig
  val run : unit -> unit

  val run_with :
    ?stream_fn:Pera_core.Agent_types.stream_fn -> Resolved_inputs.t -> unit
end

module Cli_args : module type of Cli_args
(** Re-exported internal modules for external consumers. *)

module Config_loader : module type of Config_loader
module Config_resolver : module type of Config_resolver
module Effort_resolver : module type of Effort_resolver
module Env_reader : module type of Env_reader
module Event_renderer : module type of Event_renderer
module Input_loop : module type of Input_loop
module Models_config : module type of Models_config
module Models_loader : module type of Models_loader
module Pera_config : module type of Pera_config
module Session_path : module type of Session_path
module Shell_tool_builder : module type of Shell_tool_builder
