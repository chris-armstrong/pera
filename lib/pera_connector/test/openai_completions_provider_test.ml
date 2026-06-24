open Containers
open Pera_connector

let run_create () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw -> Openai_completions_connector.create_from_env ~env ~sw |> Result.get_exn

let expect_create_failure () =
  match run_create () with
  | _ -> None
  | exception CCResult.Get_error -> Some "API key not set"
  | exception exn -> raise exn

let test_create_fails_when_api_key_unset () =
  let has_key = Sys.getenv_opt "OPENAI_API_KEY" |> Option.is_some in
  if has_key then ()
  else
    match expect_create_failure () with
    | None ->
        Alcotest.fail
          "Expected create_from_env to return Error when OPENAI_API_KEY is unset"
    | Some _ -> ()

let test_satisfies_provider_s () =
  let (_ : (module Connector.S)) = (module Openai_completions_connector) in
  ()

let () =
  Alcotest.run "OpenAI_completions_provider"
    [
      ( "create",
        [
          Alcotest.test_case "fails_when_api_key_unset" `Quick
            test_create_fails_when_api_key_unset;
        ] );
      ( "interface",
        [
          Alcotest.test_case "satisfies_provider_s" `Quick
            test_satisfies_provider_s;
        ] );
    ]
