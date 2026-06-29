open Containers

type command_result = Send of string | Compact | Info | Quit | Error of string

let is_tty ~stdin_isatty = stdin_isatty

let expand_template ~template ~args =
  let tokens =
    String.split_on_char ' ' args
    |> List.filter (fun s -> not (String.is_empty s))
  in
  let re =
    Re.(compile (seq [ char '{'; group (rep1 (compl [ char '}' ])); char '}' ]))
  in
  Re.replace re template ~f:(fun g ->
      let name = Re.Group.get g 1 in
      if String.equal name "args" then args
      else
        match Int.of_string name with
        | Some n ->
            let idx = n - 1 in
            List.nth_opt tokens idx |> Option.get_or ~default:""
        | None -> "")

let parse_line ~commands line =
  let trimmed = String.trim line in
  if String.is_empty trimmed then Send ""
  else if String.length trimmed >= 1 && Char.equal trimmed.[0] '/' then
    let rest = String.sub trimmed 1 (String.length trimmed - 1) in
    let parts = String.split_on_char ' ' rest in
    match parts with
    | [] -> Send ""
    | cmd :: cmd_args -> (
        let cmd_args_str = String.concat " " cmd_args in
        match cmd with
        | "compact" -> Compact
        | "info" -> Info
        | "quit" | "q" -> Quit
        | _ -> (
            match
              List.find_opt
                (fun (c : Pera_config.command_def) -> String.equal c.name cmd)
                commands
            with
            | Some c ->
                Send (expand_template ~template:c.template ~args:cmd_args_str)
            | None ->
                Error
                  (Printf.sprintf "unknown command /%s (type /info for help)"
                     cmd)))
  else Send trimmed
