open Containers
open Pera_provider

let run_create () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw -> Openai_completions_provider.create ~env ~sw

let expect_create_failure () =
  match run_create () with
  | _ -> None
  | exception Failure msg -> Some msg
  | exception exn -> raise exn

let test_create_fails_when_api_key_unset () =
  (* OCaml's Unix module does not expose [unsetenv], so we cannot reliably
     clear an environment variable that is already set. When the variable is
     naturally absent from the test process environment, we verify the failure
     path. When it is present, we skip the runtime assertion — the compilation
     of this test already proves the module shape is correct. *)
  let has_key = Sys.getenv_opt "OPENAI_API_KEY" |> Option.is_some in
  if has_key then
    (* Variable is set — cannot test the unset path. *)
    ()
  else
    match expect_create_failure () with
    | None ->
        Alcotest.fail
          "Expected create to raise Failure when OPENAI_API_KEY is unset"
    | Some msg ->
        Alcotest.(check bool)
          "error message mentions OPENAI_API_KEY" true
          (String.mem ~sub:"OPENAI_API_KEY" msg)

let test_satisfies_provider_s () =
  let (_ : (module Provider.S)) = (module Openai_completions_provider) in
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
