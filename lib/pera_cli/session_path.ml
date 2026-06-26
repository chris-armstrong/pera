let generate_filename ~secure_random ~wall_time =
  let buf = Bytes.create 16 in
  secure_random buf;
  let uuid = Uuidm.v4 buf in
  let t = wall_time () in
  Printf.sprintf "%04d%02d%02d_%02d%02d%02d_%s.jsonl" (t.Unix.tm_year + 1900)
    (t.Unix.tm_mon + 1) t.Unix.tm_mday t.Unix.tm_hour t.Unix.tm_min
    t.Unix.tm_sec (Uuidm.to_string uuid)

let default_session_dir home =
  Fpath.(to_string (v home / ".local" / "state" / "pera" / "sessions"))

let resolve ~session_override ~session_dir ~secure_random ~wall_time =
  match session_override with
  | Some p -> p
  | None ->
      let fname = generate_filename ~secure_random ~wall_time in
      Fpath.(to_string (v session_dir / fname))
