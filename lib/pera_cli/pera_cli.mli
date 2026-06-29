(** Reusable CLI wiring for Pera.

    The [Make] functor takes an [Env] module that describes the execution
    environment (OS process, stdin/stdout, filesystem) and produces [run] and
    [run_with] entry points. *)

(** The environment the CLI runs against — two distinct concerns in one module.

    {1 Agent execution context}

    [create], [tools], and [has_shell] describe the environment in which the
    agent's tools execute. This may be a local process, a sandbox, a container,
    or a remote system accessed over an API. The CLI must never use any of
    these to perform its own work — doing so couples pera-cli's bootstrap to
    whatever sandbox the agent is running in.

    Concretely: do not call [(val ctx).Sh.exec] for API key commands, config
    file lookup, or any other CLI-level operation. Use [Eio.Stdenv] / [Unix] /
    [Sys] directly for those.

    {1 Host process accessors}

    [getenv_opt], [home], [secure_random], and [wall_time] are functions of the
    {i real host process} where pera is running. They are declared here only so
    they can be injected in tests (replacing [Sys.getenv_opt] /
    [Unix.gettimeofday] with deterministic stubs) — they must always reflect the
    host, never a sandboxed execution environment.

    Implementors must bind these to host-process primitives:
    [getenv_opt = Sys.getenv_opt], [home] from [HOME] or [passwd], etc. A
    custom [Env] that proxies [getenv_opt] to a sandboxed env-var source is
    incorrect and will cause config resolution to fail silently. *)
module type Env = sig
  type ctx = (module Pera_env.Execution_env.S)

  (** {2 Agent execution context — may be sandboxed or remote} *)

  val create : env:Eio_unix.Stdenv.base -> sw:Eio.Switch.t -> cwd:string -> ctx
  (** Create the agent tool execution context for the given working directory. *)

  val tools :
    ctx -> (module Pera_env.Execution_env.S) Pera_core.Agent_types.tool list
  (** Return the base tool list for this environment. *)

  val has_shell : bool
  (** [true] if this environment supports shell-backed tools. *)

  (** {2 Host process accessors — always the real host, injected for testability} *)

  val getenv_opt : string -> string option
  (** Read an environment variable from the {i host process}. Must be
      [Sys.getenv_opt] in production; may be a [Hashtbl]-backed stub in tests.
      Never proxy to a sandboxed or remote environment. *)

  val home : unit -> string
  (** Home directory of the user running pera on the {i host}. Must come from
      [HOME] / [getpwuid] in production. *)

  val secure_random : env:Eio_unix.Stdenv.base -> bytes -> unit
  (** Fill [bytes] with random data from the {i host} OS entropy source. *)

  val wall_time : unit -> Unix.tm
  (** Current local time on the {i host}. Used for session file naming. *)

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
