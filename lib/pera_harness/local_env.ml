open Containers

module Sh = struct
  [@@@warning "-16"]

  let exec ~command ?cwd ?env ?timeout ?on_stdout ?on_stderr ~sw ~cancel =
    let _ = (command, cwd, env, timeout, on_stdout, on_stderr, sw, cancel) in
    Error
      {
        Pera_types.Types.code = Unknown;
        message = "shell execution not implemented in Stage 1";
      }

  let find_executable ~name =
    let _ = name in
    None
end

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
