val for_model : Pera_types.Types.model -> int
(** The model's input context window in tokens. Known ids -> exact; otherwise a conservative
    default of 200_000. *)

val default_ratio : float
(** 0.70 — the fraction of the window at which compaction should trigger (spec §8). *)

val default_trigger_tokens : ?ratio:float -> Pera_types.Types.model -> int
(** [int_of_float (ratio *. float (for_model model))]. *)
