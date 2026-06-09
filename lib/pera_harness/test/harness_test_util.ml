open Containers [@@warning "-33"]

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
