[@@@warning "-33"]

open Containers

(* Items in the internal stream are either a real event or a sentinel None
   indicating that the producer is done. The sentinel triggers the consumer
   to check the result promise for the final Ok/Error value. *)
type ('event, 'result) t = {
  stream : 'event option Eio.Stream.t;
  result :
    ('result, string) result Eio.Promise.t
    * ('result, string) result Eio.Promise.u;
}

let create ~capacity =
  let stream = Eio.Stream.create capacity in
  let result = Eio.Promise.create () in
  { stream; result }

let push t event = Eio.Stream.add t.stream (Some event)

let close t final_result =
  let _promise, resolver = t.result in
  Eio.Promise.resolve resolver (Ok final_result);
  Eio.Stream.add t.stream None

let close_error t msg =
  let _promise, resolver = t.result in
  Eio.Promise.resolve resolver (Error msg);
  Eio.Stream.add t.stream None

let take t =
  match Eio.Stream.take t.stream with
  | Some event -> `Event event
  | None -> (
      let promise, _resolver = t.result in
      let r = Eio.Promise.await promise in
      match r with Ok v -> `Done v | Error msg -> `Error msg)

let iter t ~f =
  let rec loop () =
    match take t with
    | `Event event ->
        f event;
        loop ()
    | `Done r -> Ok r
    | `Error msg -> Error msg
  in
  loop ()

let result t =
  let promise, _resolver = t.result in
  Eio.Promise.await promise
