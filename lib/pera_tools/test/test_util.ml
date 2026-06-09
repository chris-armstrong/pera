let make_temp_dir = Harness_test_util.make_temp_dir

(** Write a file via env, asserting success for test setup. *)
let write_file (module E : Pera_env.Execution_env.S) ~path ~content ~sw =
  match E.Fs.write_file ~path ~content ~sw with
  | Ok () -> ()
  | Error e -> Alcotest.failf "write_file %s failed: %s" path e.message
