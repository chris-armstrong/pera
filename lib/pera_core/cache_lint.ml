open Containers

let src = Logs.Src.create "pera.cache_lint" ~doc:"Cache-stability linter"

module Log = (val Logs.src_log src : Logs.LOG)

type pattern = { name : string; regex : Re.re }

let patterns =
  [
    {
      name = "ISO 8601 timestamp";
      regex =
        Re.compile
          (Re.Perl.re "\\b[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}");
    };
    {
      name = "RFC 3339 date";
      regex = Re.compile (Re.Perl.re "\\b[0-9]{4}-[0-9]{2}-[0-9]{2}\\b");
    };
    {
      name = "UUID v4";
      regex =
        Re.compile
          (Re.Perl.re
             "\\b[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\b");
    };
    {
      name = "long digit run";
      regex = Re.compile (Re.Perl.re "\\b[0-9]{10,}\\b");
    };
  ]

let warn_if_dynamic ?(quiet = false) ~field text =
  if quiet then ()
  else
    List.find_map
      (fun { name; regex } ->
        match Re.all regex text with
        | [] -> None
        | match_ :: _ ->
            let matched = Re.Group.get match_ 0 in
            Some (name, matched))
      patterns
    |> Option.iter (fun (name, matched) ->
        Log.warn (fun k ->
            k "[cache] %s appears to contain dynamic content (%s): %S" field
              name matched))
