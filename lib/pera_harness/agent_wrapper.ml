open Containers [@@warning "-33"]

(** {1 Internal message type} *)

type msg =
  | Run of {
      messages : Pera_core.Agent_types.agent_message list;
      reply : unit Eio.Promise.u;
    }

(** {1 Wrapper state} *)

type 'ctx t = {
  config : 'ctx Pera_core.Agent_loop.agent_loop_config;
  mailbox : msg Eio.Stream.t;  (** capacity 1 *)
  mutable subscribers : (Pera_core.Agent_types.agent_event -> unit) list;
  mutable is_running : bool;
  mutable in_flight_tools : (string * string) list;
      (** [(tool_call_id, tool_name)] pairs, keyed by id for independent removal *)
  mutable messages : Pera_core.Agent_types.agent_message list;
  sub_mutex : Eio.Mutex.t;  (** protects [subscribers] list only *)
}

(** {1 State update} *)

(** [update_state t event] mutates the observable state fields of [t] based on
    the event.  Called from the actor fibre before fan-out. *)
let update_state t event =
  match event with
  | Pera_core.Agent_types.AE_tool_execution_start { tool_call_id; tool_name; _ }
    ->
      t.in_flight_tools <- (tool_call_id, tool_name) :: t.in_flight_tools
  | Pera_core.Agent_types.AE_tool_execution_end { tool_call_id; _ } ->
      t.in_flight_tools <-
        List.filter
          (fun (id, _) -> not (String.equal id tool_call_id))
          t.in_flight_tools
  | Pera_core.Agent_types.AE_agent_end { messages } -> t.messages <- messages
  | _ -> ()

(** {1 Public interface} *)

let create ~config ~sw =
  let t =
    {
      config;
      mailbox = Eio.Stream.create 1;
      subscribers = [];
      is_running = false;
      in_flight_tools = [];
      messages = [];
      sub_mutex = Eio.Mutex.create ();
    }
  in
  (* fork_daemon: the actor runs an infinite loop; using fork would cause the
     switch to block forever waiting for a fibre that never terminates. The
     daemon is cancelled automatically when all non-daemon fibres under [sw]
     complete, giving it the correct lifetime relative to its callers. *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec loop () =
        let (Run { messages; reply }) = Eio.Stream.take t.mailbox in
        t.is_running <- true;
        Fun.protect
          ~finally:(fun () ->
            t.is_running <- false;
            t.in_flight_tools <- [];
            Eio.Cancel.protect (fun () -> Eio.Promise.resolve reply ()))
          (fun () ->
            let stream =
              Pera_core.Agent_loop.run t.config ~messages ~sw
            in
            ignore
              (Pera_provider.Event_stream.iter stream ~f:(fun event ->
                   update_state t event;
                   let subs =
                     Eio.Mutex.use_ro t.sub_mutex (fun () -> t.subscribers)
                   in
                   List.iter (fun sub -> sub event) subs)));
        loop ()
      in
      (try loop () with
       | Eio.Cancel.Cancelled _ -> ()
       | exn ->
         Printf.eprintf "agent_wrapper: actor loop terminated: %s\n%!"
           (Printexc.to_string exn));
      `Stop_daemon);
  t

let subscribe t f =
  Eio.Mutex.use_rw ~protect:false t.sub_mutex (fun () ->
      t.subscribers <- t.subscribers @ [ f ]);
  fun () ->
    Eio.Mutex.use_rw ~protect:false t.sub_mutex (fun () ->
        t.subscribers <-
          List.filter (fun sub -> not (Stdlib.(==) sub f)) t.subscribers)

let send t ~messages =
  let p, resolver = Eio.Promise.create () in
  Eio.Stream.add t.mailbox (Run { messages; reply = resolver });
  Eio.Promise.await p

let is_streaming t = t.is_running

let pending_tool_call_names t = List.map snd t.in_flight_tools

let current_messages t = t.messages
