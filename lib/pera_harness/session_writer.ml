open Containers

type t = {
  path : string;
  base : Eio.Fs.dir_ty Eio.Path.t;
  session_id : string;
  model : Pera_types.Types.model;
  cwd : string;
  mutable current_parent_id : Entry_id.t option;
}

let session_id t = t.session_id
let current_parent_id t = t.current_parent_id

(* ── Error handling ──────────────────────────────────────────────────────── *)

let catch_write path fn =
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

(* ── Low-level append ────────────────────────────────────────────────────── *)

let append_line t json =
  catch_write t.path (fun () ->
      let line = Yojson.Safe.to_string json ^ "\n" in
      Eio.Path.with_open_out ~append:true ~create:(`If_missing 0o644)
        Eio.Path.(t.base / t.path)
        (fun file ->
          Eio.Flow.copy_string line file;
          Eio.File.sync file))

(* ── create ──────────────────────────────────────────────────────────────── *)

let create ~path ~env ~model ~cwd =
  let base = env#fs in
  let open Result.Syntax in
  let parent = Filename.dirname path in
  let* () =
    if String.equal parent "." then Ok ()
    else
      catch_write path (fun () ->
          Eio.Path.mkdirs ~exists_ok:true ~perm:0o755
            Eio.Path.(base / parent))
  in
  let session_id = Entry_id.to_string (Entry_id.generate ()) in
  Ok { path; base; session_id; model; cwd; current_parent_id = None }

(* ── Writers ─────────────────────────────────────────────────────────────── *)

let write_session_info t =
  let open Result.Syntax in
  let id = Entry_id.generate () in
  let entry =
    Session_types.SessionInfo
      {
        id;
        timestamp = Unix.gettimeofday ();
        session_id = t.session_id;
        cwd = t.cwd;
        model = t.model;
        parent_session_id = None;
      }
  in
  let* () = append_line t (Session_types.entry_to_json entry) in
  t.current_parent_id <- Some id;
  Ok ()

let write_message t message =
  let open Result.Syntax in
  let id = Entry_id.generate () in
  let entry =
    Session_types.Message
      {
        id;
        parent_id = t.current_parent_id;
        timestamp = Unix.gettimeofday ();
        message;
      }
  in
  let* () = append_line t (Session_types.entry_to_json entry) in
  t.current_parent_id <- Some id;
  Ok ()

let write_leaf t =
  let open Result.Syntax in
  let id = Entry_id.generate () in
  let entry =
    Session_types.Leaf
      { id; parent_id = t.current_parent_id; timestamp = Unix.gettimeofday () }
  in
  (* Non-advancing: do NOT update current_parent_id *)
  let* () = append_line t (Session_types.entry_to_json entry) in
  Ok ()

let write_model_change t model =
  let open Result.Syntax in
  let id = Entry_id.generate () in
  let entry =
    Session_types.ModelChange
      {
        id;
        parent_id = t.current_parent_id;
        timestamp = Unix.gettimeofday ();
        model;
      }
  in
  let* () = append_line t (Session_types.entry_to_json entry) in
  t.current_parent_id <- Some id;
  Ok ()
