open Containers [@@warning "-33"]
module Faux_provider = Faux_provider

let agent_event_testable =
  Alcotest.testable Pera_core.Agent_types.pp_agent_event
    Pera_core.Agent_types.equal_agent_event
