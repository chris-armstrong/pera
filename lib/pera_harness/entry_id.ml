open Containers

type t = string

let rand_state = Random.State.make_self_init ()

let now_ms () = Int64.of_float (Unix.gettimeofday () *. 1000.)

let gen = Uuidm.v7_non_monotonic_gen ~now_ms rand_state

let generate () = Uuidm.to_string (gen ())
