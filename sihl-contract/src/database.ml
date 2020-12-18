let prepare_requests search_query filter_fragment sort_field output_type =
  let asc_request =
    let input_type = Caqti_type.int in
    let query =
      Printf.sprintf "%s ORDER BY %s ASC %s" search_query sort_field "LIMIT $1"
    in
    Caqti_request.collect input_type output_type query
  in
  let desc_request =
    let input_type = Caqti_type.int in
    let query =
      Printf.sprintf "%s ORDER BY %s DESC %s" search_query sort_field "LIMIT $1"
    in
    Caqti_request.collect input_type output_type query
  in
  let filter_asc_request =
    let input_type = Caqti_type.(tup2 string int) in
    let query =
      Printf.sprintf
        "%s %s ORDER BY %s ASC %s"
        search_query
        filter_fragment
        sort_field
        "LIMIT $2"
    in
    Caqti_request.collect input_type output_type query
  in
  let filter_desc_request =
    let input_type = Caqti_type.(tup2 string int) in
    let query =
      Printf.sprintf
        "%s %s ORDER BY %s DESC %s"
        search_query
        filter_fragment
        sort_field
        "LIMIT $2"
    in
    Caqti_request.collect input_type output_type query
  in
  asc_request, desc_request, filter_asc_request, filter_desc_request
;;

let run_request connection requests sort filter limit =
  let module Connection = (val connection : Caqti_lwt.CONNECTION) in
  let r1, r2, r3, r4 = requests in
  let result =
    match sort, filter with
    | `Asc, None -> Connection.collect_list r1 limit
    | `Desc, None -> Connection.collect_list r2 limit
    | `Asc, Some filter -> Connection.collect_list r3 (filter, limit)
    | `Desc, Some filter -> Connection.collect_list r4 (filter, limit)
  in
  result
  |> Lwt.map (Result.map_error Caqti_error.show)
  |> Lwt.map (Result.map_error failwith)
  |> Lwt.map Result.get_ok
;;

module Ql = struct
  open Sexplib.Std

  module Filter = struct
    type op =
      | Eq
      | Like
    [@@deriving show, eq, sexp, yojson]

    type criterion =
      { key : string
      ; value : string
      ; op : op
      }
    [@@deriving show, eq, sexp, yojson]

    type t =
      | And of t list
      | Or of t list
      | C of criterion
    [@@deriving show, eq, sexp, yojson]
  end

  module Sort = struct
    type criterion =
      | Asc of string
      | Desc of string
    [@@deriving show, eq, sexp, yojson]

    type t = criterion list [@@deriving show, eq, sexp, yojson]

    let criterion_value = function
      | Asc value -> value
      | Desc value -> value
    ;;
  end

  module Page = struct
    type t =
      { limit : int option [@sexp.option]
      ; offset : int option [@sexp.option]
      }
    [@@deriving show, eq, sexp, yojson]

    let empty = { limit = None; offset = None }
    let set_limit limit page = { page with limit = Some limit }
    let set_offset offset page = { page with offset = Some offset }
    let get_limit page = page.limit
    let get_offset page = page.offset

    let of_string str =
      if String.equal str ""
      then Ok empty
      else (
        let sexp = Sexplib.Sexp.of_string str in
        Ok (t_of_sexp sexp))
    ;;

    let to_string query =
      let sexp = query |> sexp_of_t in
      Sexplib.Sexp.to_string sexp
    ;;
  end

  type t =
    { filter : Filter.t option [@sexp.option]
    ; sort : Sort.t option [@sexp.option]
    ; page : Page.t
    }
  [@@deriving show, eq, sexp, yojson]

  let get_page query = query.page
  let get_limit query = query.page.limit
  let get_offset query = query.page.offset

  module Sql = struct
    let is_field_whitelisted whitelist field =
      whitelist |> List.find_opt (String.equal field) |> Option.is_some
    ;;

    let limit limit = "LIMIT ?", [ Int.to_string limit ]
    let offset offset = "OFFSET ?", [ Int.to_string offset ]

    let sort whitelist sort =
      let sorts =
        sort
        |> List.filter (fun criterion ->
               criterion |> Sort.criterion_value |> is_field_whitelisted whitelist)
        |> List.map (function
               | Sort.Asc value -> Printf.sprintf "%s ASC" value
               | Sort.Desc value -> Printf.sprintf "%s DESC" value)
        |> String.concat ", "
      in
      if String.equal "" sorts then "" else Printf.sprintf "ORDER BY %s" sorts
    ;;

    let filter_criterion_to_string criterion =
      let op_string =
        Filter.(
          match criterion.op with
          | Eq -> "="
          | Like -> "LIKE")
      in
      Printf.sprintf "%s %s ?" criterion.key op_string
    ;;

    let is_filter_whitelisted whitelist filter =
      match filter with
      | Filter.C criterion -> is_field_whitelisted whitelist Filter.(criterion.key)
      | _ -> true
    ;;

    let filter whitelist filter =
      let values = ref [] in
      let rec to_string filter =
        Filter.(
          match filter with
          | C criterion ->
            values := List.concat [ !values; [ criterion.value ] ];
            filter_criterion_to_string criterion
          | And [] -> ""
          | Or [] -> ""
          | And filters ->
            let whitelisted_filters =
              filters |> List.filter (is_filter_whitelisted whitelist)
            in
            let criterions_string =
              whitelisted_filters |> List.map to_string |> String.concat " AND "
            in
            if List.length whitelisted_filters > 1
            then Printf.sprintf "(%s)" criterions_string
            else Printf.sprintf "%s" criterions_string
          | Or filters ->
            let whitelisted_filters =
              filters |> List.filter (is_filter_whitelisted whitelist)
            in
            let criterions_string =
              whitelisted_filters |> List.map to_string |> String.concat " OR "
            in
            if List.length whitelisted_filters > 1
            then Printf.sprintf "(%s)" criterions_string
            else Printf.sprintf "%s" criterions_string)
      in
      let result = to_string filter in
      let result =
        if String.equal "" result then "" else Printf.sprintf "WHERE %s" result
      in
      result, !values
    ;;

    let to_fragments field_whitelist query =
      let filter_qs, filter_values =
        query.filter
        |> Option.map (filter field_whitelist)
        |> Option.value ~default:("", [])
      in
      let sort_qs =
        query.sort |> Option.map (sort field_whitelist) |> Option.value ~default:""
      in
      let limit_fragment = get_limit query |> Option.map limit in
      let offset_fragment = get_offset query |> Option.map offset in
      let pagination_qs, pagination_values =
        (match limit_fragment, offset_fragment with
        | Some (limit_query, limit_value), Some (offset_query, offset_value) ->
          Some
            (limit_query ^ " " ^ offset_query, List.concat [ limit_value; offset_value ])
        | _ -> None)
        |> Option.value ~default:("", [])
      in
      filter_qs, sort_qs, pagination_qs, List.concat [ filter_values; pagination_values ]
    ;;

    let to_string field_whitelist query =
      let filter_fragment, sort_fragment, pagination_fragment, values =
        to_fragments field_whitelist query
      in
      let qs =
        List.filter
          (fun str -> not (String.equal "" str))
          [ filter_fragment; sort_fragment; pagination_fragment ]
        |> String.concat " "
      in
      qs, values
    ;;
  end

  let of_string str =
    if String.equal str ""
    then Ok { filter = None; sort = None; page = { limit = None; offset = None } }
    else (
      let sexp = Sexplib.Sexp.of_string str in
      Ok (t_of_sexp sexp))
  ;;

  let to_string query =
    let sexp = query |> sexp_of_t in
    Sexplib.Sexp.to_string sexp
  ;;

  let to_sql = Sql.to_string
  let to_sql_fragments = Sql.to_fragments
  let empty = { filter = None; sort = None; page = { limit = None; offset = None } }
  let set_filter filter query = { query with filter = Some filter }

  let set_filter_and criterion query =
    let open Filter in
    let new_filter =
      match query.filter with
      | Some filter -> And (List.append [ filter ] [ C criterion ])
      | None -> C criterion
    in
    { query with filter = Some new_filter }
  ;;

  let set_sort sort query = { query with sort = Some sort }

  let set_limit limit query =
    let page = { query.page with limit = Some limit } in
    { query with page }
  ;;

  let set_offset offset query =
    let page = { query.page with offset = Some offset } in
    { query with page }
  ;;
end

type database_type =
  | MariaDb
  | PostgreSql

(* Signature *)
let name = "sihl.service.database"

module type Sig = sig
  include Sihl_core.Container.Service.Sig

  (** [raise_error err] raises a printable caqti error [err] .*)
  val raise_error : ('a, Caqti_error.t) Result.t -> 'a

  (** [fetch_pool ()] returns the connection pool. *)
  val fetch_pool : unit -> (Caqti_lwt.connection, Caqti_error.t) Caqti_lwt.Pool.t

  (** [query ctx f] runs the query [f] on the connection pool and returns the result. If
      the query fails the Lwt.t fails as well. *)
  val query : (Caqti_lwt.connection -> 'a Lwt.t) -> 'a Lwt.t

  (** [transaction ctx f] runs the query [f] on the connection pool in a transaction and
      returns the result. If the query fails the Lwt.t fails as well and the transaction
      gets rolled back. If the database driver doesn't support transactions, [transaction]
      gracefully becomes [query]. *)
  val transaction : (Caqti_lwt.connection -> 'a Lwt.t) -> 'a Lwt.t

  val register : unit -> Sihl_core.Container.Service.t
end
