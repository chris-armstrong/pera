open Containers

let anthropic_window = 200_000
let openai_window = 128_000
let default_window = anthropic_window

let for_model (model : Pera_types.Types.model) =
  if String.equal model.api "anthropic" then anthropic_window
  else if String.equal model.api "openai-completions" then openai_window
  else if String.prefix ~pre:"claude" model.id then anthropic_window
  else if String.prefix ~pre:"gpt" model.id then openai_window
  else default_window

let default_ratio = 0.70

let default_trigger_tokens ?(ratio = default_ratio) model =
  int_of_float (ratio *. float_of_int (for_model model))
