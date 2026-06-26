(** Resolve the thinking budget from effort level and model spec. *)

val resolve :
  effort:Pera_config.effort ->
  model_spec:Models_config.model_spec ->
  (int option, string) result
(** [resolve ~effort ~model_spec] maps effort to a [thinking_budget_tokens]
    value.
    - [Low] → [Ok None] (thinking disabled)
    - [Medium] → [Ok (Some thinking_spec.budget_medium)] if the model supports
      thinking, else [Error]
    - [High] → [Ok (Some thinking_spec.budget_high)] if the model supports
      thinking, else [Error] *)
