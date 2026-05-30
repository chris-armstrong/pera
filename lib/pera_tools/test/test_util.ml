open Containers

let is_substring ~sub s =
  let sub_len = String.length sub in
  let s_len = String.length s in
  if sub_len > s_len then false
  else
    let max_start = s_len - sub_len in
    let rec check i =
      if i > max_start then false
      else if String.starts_with ~prefix:sub (String.sub s i (s_len - i)) then
        true
      else check (i + 1)
    in
    check 0

let make_temp_dir env =
  let tmpdir = Filename.get_temp_dir_name () in
  let buf = Cstruct.create 8 in
  Eio.Flow.read_exact env#secure_random buf;
  let hex =
    let hex_chars = ref [] in
    for i = 0 to Cstruct.length buf - 1 do
      let code = Cstruct.get_uint8 buf i in
      hex_chars := Printf.sprintf "%02x" code :: !hex_chars
    done;
    String.concat "" (List.rev !hex_chars)
  in
  let path = Filename.concat tmpdir ("pera_test_" ^ hex) in
  Eio.Path.(mkdirs ~exists_ok:false ~perm:0o700 (env#fs / path));
  path

let cleanup tmpdir =
  try
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote tmpdir) in
    ignore (Sys.command cmd)
  with _ -> ()

(** Write a file via env, asserting success for test setup. *)
let write_file (module E : Pera_harness.Execution_env.S) ~path ~content ~sw =
  match E.Fs.write_file ~path ~content ~sw with
  | Ok () -> ()
  | Error e -> Alcotest.failf "write_file %s failed: %s" path e.message
