[@@@warning "-33"]

open Containers

(* Items in the internal stream are either a real event or a sentinel None
   indicating that the producer is done. The sentinel triggers the consumer
   to check the result promise for the final Ok/Error value. *)
type ('event, 'result) t = {
  stream : 'event option Eio.Stream.t;
  result :
    ('result, string * Pera_types.Types.stop_error) result Eio.Promise.t
    * ('result, string * Pera_types.Types.stop_error) result Eio.Promise.u;
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

let close_error t msg stop_err =
  let _promise, resolver = t.result in
  Eio.Promise.resolve resolver (Error (msg, stop_err));
  Eio.Stream.add t.stream None

let close_provider_error t msg =
  close_error t msg (Pera_types.Types.Provider { message = msg })

let close_internal_error t msg =
  close_error t msg (Pera_types.Types.Internal { message = msg })

let take t =
  match Eio.Stream.take t.stream with
  | Some event -> `Event event
  | None -> (
      let promise, _resolver = t.result in
      let r = Eio.Promise.await promise in
      match r with
      | Ok v -> `Done v
      | Error (msg, stop_err) -> `Error (msg, stop_err))

let iter t ~f =
  let rec loop () =
    match take t with
    | `Event event ->
        f event;
        loop ()
    | `Done r -> Ok r
    | `Error (msg, stop_err) -> Error (msg, stop_err)
  in
  loop ()

let result t =
  let promise, _resolver = t.result in
  Eio.Promise.await promise
