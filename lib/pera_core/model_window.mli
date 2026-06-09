val for_model : Pera_types.Types.model -> int
(** The model's input context window in tokens. Reads the [context_window] field
    from the model record — that field is the source of truth because [id]+[api]
    cannot disambiguate variants (Claude 200K vs 1M, OpenAI-compatible models
    across 4K–256K). *)

val default_ratio : float
(** [0.70] — the fraction of the window at which compaction should trigger
    (spec §8). *)

val default_trigger_tokens : ?ratio:float -> Pera_types.Types.model -> int
(** [default_trigger_tokens ?ratio model] is
    [int_of_float (ratio *. float (for_model model))]. *)
