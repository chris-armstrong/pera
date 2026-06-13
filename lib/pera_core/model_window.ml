open Containers [@@warning "-33"]

let for_model (model : Pera_types.Types.model) = model.context_window
let default_ratio = 0.70

let default_trigger_tokens ?(ratio = default_ratio) model =
  int_of_float (ratio *. float_of_int (for_model model))
