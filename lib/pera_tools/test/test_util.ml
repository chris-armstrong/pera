open Containers

let is_substring ~sub s =
  let sub_len = String.length sub in
  let s_len = String.length s in
  if sub_len > s_len then false
  else
    let max_start = s_len - sub_len in
    let rec check i =
      if i > max_start then false
      else if String.starts_with ~prefix:sub (String.sub s i (s_len - i)) then
        true
      else check (i + 1)
    in
    check 0
