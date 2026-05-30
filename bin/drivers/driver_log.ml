(** Initialise the [Logs] reporter from the [PERA_LOG] environment variable.

    Valid values: [debug], [info], [warning], [error]. Defaults to [warning]
    when unset or unrecognised. Set [PERA_LOG=debug] to see provider-level
    debug output. *)
let setup () =
  let level =
    match Sys.getenv_opt "PERA_LOG" with
    | Some "debug" -> Logs.Debug
    | Some "info" -> Logs.Info
    | Some "error" -> Logs.Error
    | _ -> Logs.Warning
  in
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some level)
