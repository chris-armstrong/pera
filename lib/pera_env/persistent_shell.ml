open Containers

(** {1 Sentinel generation} *)

let sentinel_prefix = "PERA_DONE_"
let sentinel_rng = Random.State.make_self_init ()

let generate_sentinel () =
  let uuid = Uuidm.v4_gen sentinel_rng () in
  sentinel_prefix ^ Uuidm.to_string uuid

(** {1 Shell detection} *)

let find_shell () =
  if Sys.file_exists "/bin/bash" then "/bin/bash"
  else if Sys.file_exists "/bin/sh" then "/bin/sh"
  else failwith "persistent_shell: neither /bin/bash nor /bin/sh found"

(** {1 Shell-safe string interpolation} *)

let shell_quote = Filename.quote

(** {1 Line-based reading with sentinel detection} *)

let read_until_sentinel ~clock ~stream ~sentinel:_ ~is_sentinel_line ~on_line
    src =
  let tmp = Cstruct.create 4096 in
  let buf = Buffer.create 1024 in
  let chunks = ref [] in
  let sentinel_line = ref None in
  let rec process_buffer () =
    let s = Buffer.contents buf in
    match String.index s '\n' with
    | idx ->
        let line = String.sub s 0 idx in
        let rest_len = String.length s - idx - 1 in
        let rest = String.sub s (idx + 1) rest_len in
        Buffer.clear buf;
        Buffer.add_string buf rest;
        let timestamp = Eio.Time.now clock in
        if is_sentinel_line line then sentinel_line := Some line
        else begin
          chunks := { Execution_env.stream; timestamp; line } :: !chunks;
          Option.iter (fun f -> f (line ^ "\n")) on_line;
          process_buffer ()
        end
    | exception Not_found -> ()
  in
  let rec loop () =
    match Eio.Flow.single_read src tmp with
    | n when n > 0 ->
        let str = Cstruct.to_string (Cstruct.sub tmp 0 n) in
        Buffer.add_string buf str;
        process_buffer ();
        if Option.is_none !sentinel_line then loop ()
    | _ ->
        let remaining = Buffer.contents buf in
        if not (String.is_empty remaining) then begin
          let timestamp = Eio.Time.now clock in
          if is_sentinel_line remaining then sentinel_line := Some remaining
          else
            chunks :=
              { Execution_env.stream; timestamp; line = remaining } :: !chunks
        end
  in
  (try loop () with End_of_file -> ());
  (List.rev !chunks, !sentinel_line)

(** {1 Sentinel detection} *)

let parse_stdout_sentinel ~sentinel line =
  let suffix = " " ^ sentinel in
  if String.ends_with ~suffix line then
    let exit_str =
      String.sub line 0 (String.length line - String.length suffix)
    in
    int_of_string_opt exit_str
  else None

let is_stderr_sentinel ~sentinel line = String.equal line sentinel

(** {1 Command wrapper}

    Sends the user command followed by exit code capture and sentinel echoes.
    Commands are intentionally NOT wrapped in a subshell: [cd], [export] and
    other state-changing commands must affect the persistent shell's environment
    directly. *)

let build_command_wrapper ~command ~sentinel =
  let buf = Buffer.create (String.length command + 128) in
  let add s = Buffer.add_string buf s in
  add command;
  add "\n";
  add "EXIT_CODE=$?\n";
  add (Printf.sprintf "echo \"$EXIT_CODE %s\" 1>&1\n" sentinel);
  add (Printf.sprintf "echo \"%s\" 1>&2\n" sentinel);
  Buffer.contents buf

(** {1 Type} *)

type t = {
  proc : [ `Process | `Platform of [ `Generic | `Unix ] ] Eio.Resource.t;
  stdin : [ `W | `Flow | `Close | `Unix_fd ] Eio.Resource.t;
  stdout : [ `R | `Flow | `Close | `Unix_fd ] Eio.Resource.t;
  stderr : [ `R | `Flow | `Close | `Unix_fd ] Eio.Resource.t;
  state : [ `R | `Flow | `Close | `Unix_fd ] Eio.Resource.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  mutable closed : bool;
  mutex : Eio.Mutex.t;
  process_group : bool;
}

(** {1 Cleanup helpers}

    These intentionally swallow close/write errors: they run during cleanup when
    the underlying switch or process may already be gone. *)

let safe_close r = try Eio.Resource.close r with _ -> ()

let wait_shell t =
  try ignore (Eio.Process.await t.proc : [ `Exited of int | `Signaled of int ])
  with _ -> ()

(** {1 Close}

    If process group tracking is enabled, kills the entire process group (shell
    \+ all background jobs). Otherwise, sends ["exit"] to the shell and waits —
    background tasks survive as orphaned processes. *)

let close t =
  if not t.closed then begin
    t.closed <- true;
    let cmd =
      if t.process_group then "kill $(jobs -p) 2>/dev/null\nexit\n"
      else "exit\n"
    in
    (try Eio.Flow.write t.stdin [ Cstruct.of_string cmd ] with _ -> ());
    wait_shell t;
    safe_close t.stdin;
    safe_close t.stdout;
    safe_close t.stderr;
    safe_close t.state
  end

(** {1 Create} *)

let create ~proc_mgr ~clock ~sw ~env ~cwd ?(process_group = true) () =
  let stdin_src, stdin_sink = Eio_unix.pipe sw in
  let stdout_src, stdout_sink = Eio_unix.pipe sw in
  let stderr_src, stderr_sink = Eio_unix.pipe sw in
  let state_src, state_sink = Eio_unix.pipe sw in
  let shell_path = find_shell () in
  let stdin_src_fd = Eio_unix.Resource.fd stdin_src in
  let stdout_sink_fd = Eio_unix.Resource.fd stdout_sink in
  let stderr_sink_fd = Eio_unix.Resource.fd stderr_sink in
  let state_sink_fd = Eio_unix.Resource.fd state_sink in
  let proc =
    Eio_unix.Process.spawn_unix ~sw proc_mgr ~env
      ~fds:
        [
          (0, stdin_src_fd, `Blocking);
          (1, stdout_sink_fd, `Blocking);
          (2, stderr_sink_fd, `Blocking);
          (3, state_sink_fd, `Blocking);
        ]
      ~executable:shell_path
      [ shell_path; "--norc"; "--noprofile" ]
  in
  safe_close stdin_src;
  safe_close stdout_sink;
  safe_close stderr_sink;
  safe_close state_sink;
  let t =
    {
      proc;
      stdin = stdin_sink;
      stdout = stdout_src;
      stderr = stderr_src;
      state = state_src;
      clock;
      closed = false;
      mutex = Eio.Mutex.create ();
      process_group;
    }
  in
  (* Startup handshake: send a simple command and wait for its output. *)
  let startup_sentinel = generate_sentinel () in
  let startup_cmd =
    Printf.sprintf "printf '%%s\n' %s\n" (shell_quote startup_sentinel)
  in
  Eio.Flow.write t.stdin [ Cstruct.of_string startup_cmd ];
  let startup_tmp = Cstruct.create 4096 in
  let startup_buf = Buffer.create 64 in
  let rec wait_for_startup () =
    match Eio.Flow.single_read t.stdout startup_tmp with
    | n when n > 0 ->
        Buffer.add_string startup_buf
          (Cstruct.to_string (Cstruct.sub startup_tmp 0 n));
        let s = Buffer.contents startup_buf in
        if String.contains s '\n' then begin
          let lines = String.split_on_char '\n' s in
          if List.exists (String.equal startup_sentinel) lines then ()
          else wait_for_startup ()
        end
        else wait_for_startup ()
    | _ -> failwith "persistent_shell: shell exited during startup handshake"
  in
  wait_for_startup ();
  (* cd to initial working directory *)
  let cd_sentinel = generate_sentinel () in
  let cd_cmd =
    Printf.sprintf "cd %s && printf '%%s\n' %s\n" (shell_quote cwd)
      (shell_quote cd_sentinel)
  in
  Eio.Flow.write t.stdin [ Cstruct.of_string cd_cmd ];
  let cd_tmp = Cstruct.create 4096 in
  let cd_buf = Buffer.create 64 in
  let rec wait_for_cd () =
    match Eio.Flow.single_read t.stdout cd_tmp with
    | n when n > 0 ->
        Buffer.add_string cd_buf (Cstruct.to_string (Cstruct.sub cd_tmp 0 n));
        let s = Buffer.contents cd_buf in
        if String.contains s '\n' then begin
          let lines = String.split_on_char '\n' s in
          if List.exists (String.equal cd_sentinel) lines then ()
          else wait_for_cd ()
        end
        else wait_for_cd ()
    | _ -> failwith "persistent_shell: shell exited during cd"
  in
  wait_for_cd ();
  Eio.Switch.on_release sw (fun () -> close t);
  t

(** {1 Exec} *)

let exec t ~command ?on_stdout ?on_stderr ?timeout ~sw:_ ~cancel () =
  Eio.Cancel.check cancel;
  Eio.Mutex.lock t.mutex;
  Fun.protect
    ~finally:(fun () -> Eio.Cancel.protect (fun () -> Eio.Mutex.unlock t.mutex))
    (fun () ->
      if t.closed then
        Error
          {
            Pera_types.Types.code = Aborted;
            message = "persistent shell is closed";
          }
      else
        let sentinel = generate_sentinel () in
        let cmd = build_command_wrapper ~command ~sentinel in
        (try Eio.Flow.write t.stdin [ Cstruct.of_string cmd ] with _ -> ());
        let run_in_switch () =
          Eio.Switch.run (fun _sub_sw ->
              let stdout_chunks = ref [] in
              let stderr_chunks = ref [] in
              let stdout_sentinel = ref None in
              let stderr_sentinel = ref None in
              Eio.Fiber.all
                [
                  (fun () ->
                    let is_sentinel line =
                      Option.is_some (parse_stdout_sentinel ~sentinel line)
                    in
                    let chunks, sentinel_line =
                      read_until_sentinel ~clock:t.clock ~stream:Stdout
                        ~sentinel ~is_sentinel_line:is_sentinel
                        ~on_line:on_stdout t.stdout
                    in
                    stdout_chunks := chunks;
                    stdout_sentinel := sentinel_line);
                  (fun () ->
                    let chunks, sentinel_line =
                      read_until_sentinel ~clock:t.clock ~stream:Stderr
                        ~sentinel
                        ~is_sentinel_line:(is_stderr_sentinel ~sentinel)
                        ~on_line:on_stderr t.stderr
                    in
                    stderr_chunks := chunks;
                    stderr_sentinel := sentinel_line);
                ];
              let chunks =
                Execution_env.sort_chunks_by_timestamp
                  (List.rev !stdout_chunks @ List.rev !stderr_chunks)
              in
              let stdout_text =
                !stdout_chunks |> List.rev
                |> List.map (fun (c : Execution_env.output_chunk) -> c.line)
                |> String.concat "\n"
              in
              let stderr_text =
                !stderr_chunks |> List.rev
                |> List.map (fun (c : Execution_env.output_chunk) -> c.line)
                |> String.concat "\n"
              in
              let exit_code =
                match !stdout_sentinel with
                | Some line -> (
                    match parse_stdout_sentinel ~sentinel line with
                    | Some code -> code
                    | None -> 1)
                | None -> 1
              in
              Ok
                {
                  Execution_env.stdout = stdout_text;
                  stderr = stderr_text;
                  exit_code;
                  chunks;
                })
        in
        try
          match timeout with
          | None -> run_in_switch ()
          | Some timeout_sec -> (
              try Eio.Time.with_timeout_exn t.clock timeout_sec run_in_switch
              with Eio.Time.Timeout ->
                Error
                  {
                    Pera_types.Types.code = Timeout;
                    message =
                      Printf.sprintf "Command timed out after %.1f seconds"
                        timeout_sec;
                  })
        with Eio.Cancel.Cancelled _ ->
          Error
            { Pera_types.Types.code = Aborted; message = "Operation cancelled" })
