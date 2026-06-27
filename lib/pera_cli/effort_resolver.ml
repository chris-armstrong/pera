let resolve ~effort ~model_spec =
  match effort with
  | Pera_config.Low -> Ok None
  | Pera_config.Medium -> (
      match model_spec.Models_config.thinking with
      | Some s -> Ok (Some s.Models_config.budget_medium)
      | None ->
          Error
            (Printf.sprintf
               "[pera] model %S does not support extended thinking (effort \
                Medium/High requires a model with thinking capability)"
               model_spec.Models_config.name))
  | Pera_config.High -> (
      match model_spec.Models_config.thinking with
      | Some s -> Ok (Some s.Models_config.budget_high)
      | None ->
          Error
            (Printf.sprintf
               "[pera] model %S does not support extended thinking (effort \
                Medium/High requires a model with thinking capability)"
               model_spec.Models_config.name))
