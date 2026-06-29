module Cli = Pera_cli.Make (struct
  type ctx = (module Pera_env.Execution_env.S)

  let create ~env ~sw:_ ~cwd = Pera_env.Local_env.create ~env ~cwd
  let tools _ctx = Pera_tools.Tools.default
  let has_shell = true
  let getenv_opt = Sys.getenv_opt
  let home () = Xdg.home_dir (Xdg.create ~env:Sys.getenv_opt ())

  let secure_random ~env s =
    let src = Eio.Stdenv.secure_random env in
    let cs = Cstruct.create 16 in
    Eio.Flow.read_exact src cs;
    let got = Cstruct.to_string cs in
    Bytes.blit_string got 0 s 0 16

  let stdin_isatty ~env:_ = Unix.isatty Unix.stdin
end)

let () = Cli.run ()
