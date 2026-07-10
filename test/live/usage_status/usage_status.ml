open Containers [@@warning "-33"]

let format (u : Pera_types.Types.usage) =
  let base =
    Printf.sprintf "in=%d out=%d cache_read=%d cache_write=%d" u.input_tokens
      u.output_tokens u.cache_read_tokens u.cache_write_tokens
  in
  match u.cost_usd with
  | None -> base
  | Some d -> base ^ " cost=$" ^ Decimal.to_string d
