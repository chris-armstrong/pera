(** A long-lived shell process that preserves state (cwd, env, functions,
    aliases, options) between [exec] calls.

    Spawns [/bin/bash] (falling back to [/bin/sh] if absent) and communicates
    via four OS pipes: stdin, stdout, stderr, and a private state channel on
    file descriptor 3. The fd-3 channel is reserved for Stage 1 state snapshots
    and is not used by Stage 0; it is plumbed now so that the shell process
    already has the channel available when snapshot support lands.

    {b Protocol}

    Each [exec] call sends the user command followed by sentinel lines on stdout
    and stderr. The command is intentionally {i not} wrapped in a subshell:
    state-changing commands such as [cd] and [export] must affect the persistent
    shell directly. Exit-code capture uses bash's [$?] rather than a subshell
    wrapper. Sentinels are UUIDs of the form [PERA_DONE_<uuidv4_hex>] so
    collisions with command output are astronomically unlikely.

    Output chunks are merge-sorted by read-time timestamp, enabling wall-clock
    reconstruction of stdout/stderr interleaving.

    {b Process group tracking}

    By default, the shell is placed in its own OS process group. When the shell
    is closed (e.g. the CLI process exits), the entire process group is killed —
    including any background jobs the agent started (builds, servers,
    [sleep 1000 &], etc.). Set [~process_group:false] to disable this: the shell
    process itself is killed, but any background tasks it spawned survive as
    orphaned processes and continue running after the agent exits.

    {b Stage 0} — core protocol plus basic timeout. No fd-3 state snapshot, no
    crash detection/restart. *)

type t
(** A handle to a persistent shell process. *)

val create :
  proc_mgr:[> [ `Generic | `Unix ] Eio.Process.mgr_ty ] Eio.Resource.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  sw:Eio.Switch.t ->
  env:string array ->
  cwd:string ->
  ?process_group:bool ->
  unit ->
  t
(** [create ~proc_mgr ~clock ~sw ~env ~cwd ()] spawns [/bin/bash] (falling back
    to [/bin/sh] if absent), wired to four OS pipes (stdin, stdout, stderr, and
    a private fd-3 state channel). Sends a startup sentinel to confirm the shell
    is ready, then [cd]s to [cwd] before returning.

    The shell process's lifetime is tied to [sw]: [close] is registered via
    [Eio.Switch.on_release sw] so the shell is torn down when [sw] completes.

    @param process_group
      If [true] (default), the shell is placed in its own OS process group. When
      the shell is closed, the entire process group is killed, including any
      background jobs the agent started. Set to [false] to allow background
      tasks to survive the agent process exiting. *)

val exec :
  t ->
  command:string ->
  ?on_stdout:(string -> unit) ->
  ?on_stderr:(string -> unit) ->
  ?timeout:float ->
  sw:Eio.Switch.t ->
  cancel:Eio.Cancel.t ->
  unit ->
  (Execution_env.exec_result, Pera_types.Types.execution_error) result
(** [exec t ~command ~sw ~cancel] sends [command] to the persistent shell and
    reads back the result using the per-fd sentinel protocol.

    - The command is intentionally {i not} wrapped in a subshell so that [cd],
      [export] and other state-changing commands affect the persistent shell
      directly.
    - Reads stdout and stderr concurrently via [Eio.Fiber.all].
    - Each line is timestamped via [Eio.Time.now clock] as it is read.
    - [?on_stdout] and [?on_stderr] are called per non-sentinel line (with
      trailing newline appended).
    - Returned [chunks] are sorted by read-time timestamp for wall-clock
      interleaving reconstruction.
    - No [?cwd] or [?env] parameters — a stateful shell owns its own cwd and
      environment.

    Raises [Eio.Cancel.Cancelled] if [cancel] is triggered before or during
    execution. Returns [Error Timeout] if [?timeout] expires. *)

val close : t -> unit
(** [close t] terminates the shell and all its background jobs (if process group
    tracking is enabled). Idempotent — subsequent calls are no-ops. *)
