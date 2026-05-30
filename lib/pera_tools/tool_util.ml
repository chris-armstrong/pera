open Containers

let get_string key args =
  match args with
  | `Assoc fields -> (
      match List.assoc_opt ~eq:String.equal key fields with
      | Some (`String s) -> Ok s
      | Some other ->
          Error
            {
              Pera_types.Types.message =
                Printf.sprintf "field '%s' expected string but got %s" key
                  (Yojson.Safe.to_string other);
              is_user_error = true;
            }
      | None ->
          Error
            {
              Pera_types.Types.message =
                Printf.sprintf "required field '%s' is missing" key;
              is_user_error = true;
            })
  | _ ->
      Error
        {
          Pera_types.Types.message = "expected object arguments";
          is_user_error = true;
        }

let get_string_opt key args =
  match args with
  | `Assoc fields -> (
      match List.assoc_opt ~eq:String.equal key fields with
      | Some (`String s) -> Some s
      | _ -> None)
  | _ -> None

let get_int_opt key args =
  match args with
  | `Assoc fields -> (
      match List.assoc_opt ~eq:String.equal key fields with
      | Some (`Int n) -> Some n
      | _ -> None)
  | _ -> None

let get_float_opt key args =
  match args with
  | `Assoc fields -> (
      match List.assoc_opt ~eq:String.equal key fields with
      | Some (`Int n) -> Some (float_of_int n)
      | Some (`Float f) -> Some f
      | _ -> None)
  | _ -> None
