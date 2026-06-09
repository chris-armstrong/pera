open Containers

let create ~env ~cwd =
  let cwd_fpath = Fpath.v cwd in

  let resolve_path p =
    let fp = Fpath.v p in
    if Fpath.is_rel fp then Fpath.to_string Fpath.(cwd_fpath // fp) else p
  in

  let stat_to_file_info ~path (stat : Eio.File.Stat.t) =
    let kind =
      match stat.kind with
      | `Regular_file -> `File
      | `Directory -> `Directory
      | `Symbolic_link -> `Symlink
      | _ -> `File
    in
    let fp = Fpath.v path in
    let name = Fpath.filename fp in
    let size = Optint.Int63.to_int stat.size in
    { Execution_env.name; path; kind; size; mtime_s = stat.mtime }
  in

  let catch_fs ~path fn =
    try Ok (fn ()) with
    | Eio.Io (Eio.Fs.E (Not_found _), _) ->
        Error
          {
            Pera_types.Types.code = NotFound;
            path;
            message = Printf.sprintf "File not found: %s" path;
          }
    | Eio.Io (Eio.Fs.E (Permission_denied _), _) ->
        Error
          {
            Pera_types.Types.code = PermissionDenied;
            path;
            message = Printf.sprintf "Permission denied: %s" path;
          }
    | Eio.Io (Eio.Fs.E (Already_exists _), _) ->
        Error
          {
            Pera_types.Types.code = Unknown;
            path;
            message = Printf.sprintf "Already exists: %s" path;
          }
    | Eio.Cancel.Cancelled _ ->
        Error
          {
            Pera_types.Types.code = Aborted;
            path;
            message = "Operation cancelled";
          }
    | Eio.Io (_, _) as exn ->
        Error
          {
            Pera_types.Types.code = Unknown;
            path;
            message = Printexc.to_string exn;
          }
    | exn ->
        Error
          {
            Pera_types.Types.code = Unknown;
            path;
            message = Printexc.to_string exn;
          }
  in

  let eio_path p = Eio.Path.(env#fs / p) in

  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in

  let module Sh = struct
    [@@@warning "-16"]

    let find_executable ~name =
      let path_var = try Sys.getenv "PATH" with Not_found -> "" in
      let sep = if String.equal (Sys.os_type) "Win32" then ';' else ':' in
      String.split_on_char sep path_var
      |> List.filter (fun s -> not (String.is_empty s))
      |> List.find_map (fun dir ->
          let candidate = Fpath.to_string Fpath.(v dir / name) in
          try
            Unix.access candidate [ Unix.X_OK ];
            Some candidate
          with Unix.Unix_error _ -> None)

    let read_stream src buf cb =
      let tmp = Cstruct.create 4096 in
      let rec loop () =
        match Eio.Flow.single_read src tmp with
        | n when n > 0 ->
            let str = Cstruct.to_string (Cstruct.sub tmp 0 n) in
            Buffer.add_string buf str;
            Option.iter (fun f -> f str) cb;
            loop ()
        | _ -> ()
      in
      try loop () with End_of_file -> ()

    let await_process proc result_ref =
      match Eio.Process.await proc with
      | `Exited code -> result_ref := Some (Ok code)
      | `Signaled n -> result_ref := Some (Error n)

    let exec ~command ?cwd ?env:extra_env ?timeout ?on_stdout ?on_stderr ~sw
        ~cancel =
      let _ = sw in
      let resolved_cwd =
        match cwd with
        | Some c ->
            let p = Fpath.v c in
            if Fpath.is_rel p then Some (Fpath.to_string Fpath.(cwd_fpath // p))
            else Some c
        | None -> None
      in
      let merged_env =
        match extra_env with
        | None -> None
        | Some extra ->
            let base =
              match Unix.environment () with
              | a -> Array.to_list a
              | exception Not_found -> []
            in
            let entries = List.map (fun (k, v) -> k ^ "=" ^ v) extra in
            Some (Array.of_list (base @ entries))
      in
      let run_in_sub_switch () =
        Eio.Switch.run (fun sub_sw ->
            let stdout_buf = Buffer.create 256 in
            let stderr_buf = Buffer.create 256 in
            let stdout_src, stdout_sink =
              Eio.Process.pipe ~sw:sub_sw proc_mgr
            in
            let stderr_src, stderr_sink =
              Eio.Process.pipe ~sw:sub_sw proc_mgr
            in
            let cwd_path =
              match resolved_cwd with
              | Some p -> Some Eio.Path.(env#fs / p)
              | None -> None
            in
            let proc =
              Eio.Process.spawn ~sw:sub_sw proc_mgr ?cwd:cwd_path
                ~stdout:stdout_sink ~stderr:stderr_sink ?env:merged_env
                [ "/bin/sh"; "-c"; command ]
            in
            Eio.Resource.close stdout_sink;
            Eio.Resource.close stderr_sink;
            let result = ref None in
            Eio.Fiber.all
              [
                (fun () -> read_stream stdout_src stdout_buf on_stdout);
                (fun () -> read_stream stderr_src stderr_buf on_stderr);
                (fun () -> await_process proc result);
              ];
            match !result with
            | Some (Ok code) ->
                Ok
                  {
                    Execution_env.stdout = Buffer.contents stdout_buf;
                    stderr = Buffer.contents stderr_buf;
                    exit_code = code;
                  }
            | Some (Error n) ->
                Error
                  {
                    Pera_types.Types.code = Aborted;
                    message = Printf.sprintf "Process was killed by signal %d" n;
                  }
            | None -> failwith "exec: process awaiter did not produce a result")
      in
      let run_with_timeout t =
        try Eio.Time.with_timeout_exn clock t run_in_sub_switch
        with Eio.Time.Timeout ->
          Error
            {
              Pera_types.Types.code = Timeout;
              message = Printf.sprintf "Command timed out after %.1f seconds" t;
            }
      in
      Eio.Cancel.check cancel;
      try
        match timeout with
        | None -> run_in_sub_switch ()
        | Some t -> run_with_timeout t
      with Eio.Cancel.Cancelled _ ->
        Error
          { Pera_types.Types.code = Aborted; message = "Operation cancelled" }
  end in
  let module Fs = struct
    let read_text_file ~path ~sw =
      let _ = sw in
      catch_fs ~path (fun () ->
          let ep = eio_path (resolve_path path) in
          Eio.Path.load ep)

    let write_file ~path ~content ~sw =
      let _ = sw in
      catch_fs ~path (fun () ->
          let resolved = resolve_path path in
          (* Create parent directories *)
          let parent = Fpath.parent (Fpath.v resolved) in
          let parent_str = Fpath.to_string parent in
          if
            (not (String.is_empty parent_str))
            && not (String.equal parent_str ".")
          then (
            let parent_ep = eio_path parent_str in
            Eio.Path.mkdirs parent_ep ~exists_ok:true ~perm:0o755;
            let ep = eio_path resolved in
            Eio.Path.save ~create:(`Or_truncate 0o644) ep content))

    let append_file ~path ~content ~sw =
      let _ = sw in
      catch_fs ~path (fun () ->
          let resolved = resolve_path path in
          let parent = Fpath.parent (Fpath.v resolved) in
          let parent_str = Fpath.to_string parent in
          if
            (not (String.is_empty parent_str))
            && not (String.equal parent_str ".")
          then (
            let parent_ep = eio_path parent_str in
            Eio.Path.mkdirs parent_ep ~exists_ok:true ~perm:0o755;
            let ep = eio_path resolved in
            Eio.Path.save ~create:(`If_missing 0o644) ~append:true ep content))

    let list_dir ~path ~sw =
      let _ = sw in
      catch_fs ~path (fun () ->
          let ep = eio_path (resolve_path path) in
          let names = Eio.Path.read_dir ep in
          let resolved_dir = resolve_path path in
          let entry_to_file_info name =
            let entry_path = Fpath.to_string Fpath.(v resolved_dir / name) in
            let entry_ep = eio_path entry_path in
            let stat = Eio.Path.stat ~follow:true entry_ep in
            stat_to_file_info ~path:entry_path stat
          in
          List.map entry_to_file_info names)

    let file_info ~path ~sw =
      let _ = sw in
      catch_fs ~path (fun () ->
          let resolved = resolve_path path in
          let ep = eio_path resolved in
          let stat = Eio.Path.stat ~follow:true ep in
          stat_to_file_info ~path:resolved stat)

    let exists ~path ~sw =
      let _ = sw in
      catch_fs ~path (fun () ->
          let ep = eio_path (resolve_path path) in
          match Eio.Path.kind ~follow:true ep with
          | `Not_found -> false
          | _ -> true)

    let create_dir ~path ~sw =
      let _ = sw in
      catch_fs ~path (fun () ->
          let ep = eio_path (resolve_path path) in
          Eio.Path.mkdirs ep ~exists_ok:false ~perm:0o755)

    let absolute_path p =
      let fp = Fpath.v p in
      if Fpath.is_rel fp then Ok Fpath.(to_string (cwd_fpath // fp)) else Ok p

    let join_path segments =
      let base =
        List.fold_left (fun acc seg -> Fpath.(acc / seg)) (Fpath.v "") segments
      in
      Fpath.to_string base

    let canonical_path ~path ~sw =
      let _ = sw in
      catch_fs ~path (fun () ->
          let resolved = resolve_path path in
          Unix.realpath resolved)
  end in
  (module struct
    module Fs = Fs
    module Sh = Sh
  end : Execution_env.S)
