open Containers

(** Smoke test: verify that [Pera_cli.Make.run_with] assembles the full pipeline
    (config resolution → harness creation → event subscription) without
    crashing, using a faux stream_fn to bypass real network calls. *)

let temp_dir () =
  let dir = Filename.get_temp_dir_name () in
  let tmp =
    Filename.concat dir (Printf.sprintf "pera_smoke_%d" (Unix.getpid ()))
  in
  Unix.mkdir tmp 0o700;
  tmp

let rmdir dir =
  let rec loop path =
    if Sys.is_directory path then (
      Array.iter (fun f -> loop (Filename.concat path f)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  loop dir

(** A canned [getenv_opt] that returns a fixed API key for the "faux" provider
    and nothing else. *)
let test_getenv_opt var =
  if String.equal var "FAUX_API_KEY" then Some "test-api-key" else None

(** A [secure_random] stub that writes deterministic bytes. *)
let fixed_random buf = Bytes.fill buf 0 16 '\x00'

(** Build a minimal [Models_config.models_file] with one provider and one model.
*)
let test_models_file () : Pera_cli.Models_config.models_file =
  let open Pera_cli.Models_config in
  {
    providers =
      [
        {
          name = "faux";
          protocol = "faux";
          api_key_env = [ "FAUX_API_KEY" ];
          api = None;
          api_env = None;
          compat = None;
          models =
            [
              {
                name = "test-model";
                context_window = 100_000;
                max_tokens = 16_000;
                thinking = None;
                cost = None;
              };
            ];
        };
      ];
  }

(** Build a minimal [Cli_args.parsed_args] with just a model. *)
let test_parsed_args () : Pera_cli.Cli_args.parsed_args =
  let open Pera_cli.Cli_args in
  {
    model = Some "faux/test-model";
    api_key = None;
    api_key_file = None;
    api_key_command = None;
    effort = None;
    max_tokens = None;
    cache_policy = None;
    cache_ttl = None;
    session = None;
    session_dir = None;
    cwd = None;
    system = None;
    system_file = None;
    no_compact = false;
    compact_threshold = None;
    compact_tail = None;
    show_thinking = false;
    quiet = false;
    json = false;
    input = None;
    input_file = None;
    list_models = false;
  }

(** Build a [Config_resolver.resolve_inputs] from the test fixtures. *)
let test_resolve_inputs ~home () : Pera_cli.Config_resolver.resolve_inputs =
  let open Pera_cli.Config_resolver in
  {
    parsed_args = test_parsed_args ();
    models_file = test_models_file ();
    user_config = None;
    project_config = None;
    getenv_opt = test_getenv_opt;
    home;
  }

(** A mock [Env] for the smoke test. Uses a temporary directory for the
    execution environment. *)
module Smoke_env : Pera_cli.Env = struct
  type ctx = (module Pera_env.Execution_env.S)

  let create ~env ~sw:_ ~cwd = Pera_env.Local_env.create ~env ~cwd
  let tools _ctx = Pera_tools.Tools.default
  let has_shell = true
  let getenv_opt = test_getenv_opt
  let home () = "/tmp/pera_smoke_home"
  let secure_random ~env:_ = fixed_random
end

module Smoke_cli = Pera_cli.Make (Smoke_env)

(** Build a faux [stream_fn] that emits a single text delta and closes with a
    final message. *)
let faux_stream_fn =
  let open Pera_types.Types in
  let final_msg =
    {
      content = [ AText "hello from smoke test" ];
      stop_reason = EndTurn;
      provenance =
        {
          protocol = "faux";
          provider = "faux";
          model = "test-model";
          error_message = None;
        };
      usage =
        {
          input_tokens = 10;
          output_tokens = 5;
          cache_read_tokens = 0;
          cache_write_tokens = 0;
          cost_usd = None;
        };
    }
  in
  let script =
    Pera_core_test_util.Faux_provider.Turn
      {
        events =
          [
            AME_text_delta
              { text = "hello from smoke test"; partial = final_msg };
          ];
        final = final_msg;
      }
  in
  Pera_core_test_util.Faux_provider.stream_fn_of_scripts [ script ]

(** Test: [run_with] assembles the pipeline without crashing. *)
let test_run_with_assembles_pipeline () =
  let tmp = temp_dir () in
  Fun.protect
    (fun () ->
      let inputs = test_resolve_inputs ~home:tmp () in
      Smoke_cli.run_with ~stream_fn:faux_stream_fn inputs)
    ~finally:(fun () -> rmdir tmp)

let () =
  Alcotest.run "pera-smoke"
    [
      ( "smoke",
        [
          Alcotest.test_case "run_with assembles pipeline" `Quick
            test_run_with_assembles_pipeline;
        ] );
    ]
