open Lwt.Syntax
module Core = Sihl_core

let log_src = Logs.Src.create ("sihl.service." ^ Sihl_contract.Database.name)

module Logs = (val Logs.src_log log_src : Logs.LOG)

let pool_ref : (Caqti_lwt.connection, Caqti_error.t) Caqti_lwt.Pool.t option ref
  =
  ref None
;;

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

type config =
  { url : string
  ; pool_size : int option
  }

let config url pool_size = { url; pool_size }

let schema =
  let open Conformist in
  make
    [ string ~meta:"The database connection url" "DATABASE_URL"
    ; optional (int ~default:5 "DATABASE_POOL_SIZE")
    ]
    config
;;

let raise_error err =
  match err with
  | Error err -> raise (Sihl_contract.Database.Exception (Caqti_error.show err))
  | Ok result -> result
;;

let print_pool_usage pool =
  let n_connections = Caqti_lwt.Pool.size pool in
  let max_connections =
    Option.value (Core.Configuration.read schema).pool_size ~default:10
  in
  Logs.debug (fun m -> m "Pool usage: %i/%i" n_connections max_connections)
;;

let fetch_pool () =
  match !pool_ref with
  | Some pool ->
    Logs.debug (fun m -> m "Skipping pool creation, re-using existing pool");
    pool
  | None ->
    let pool_size =
      Option.value (Core.Configuration.read schema).pool_size ~default:10
    in
    Logs.debug (fun m -> m "Create pool with size %i" pool_size);
    (Core.Configuration.read schema).url
    |> Uri.of_string
    |> Caqti_lwt.connect_pool ~max_size:pool_size
    |> (function
    | Ok pool ->
      pool_ref := Some pool;
      pool
    | Error err ->
      let msg = "Failed to connect to DB pool" in
      Logs.err (fun m -> m "%s %s" msg (Caqti_error.show err));
      raise (Sihl_contract.Database.Exception ("Failed to create pool " ^ msg)))
;;

let transaction f =
  let pool = fetch_pool () in
  print_pool_usage pool;
  let* result =
    Caqti_lwt.Pool.use
      (fun connection ->
        Logs.debug (fun m -> m "Fetched connection from pool");
        let (module Connection : Caqti_lwt.CONNECTION) = connection in
        let* start_result = Connection.start () in
        match start_result with
        | Error msg ->
          Logs.debug (fun m ->
              m "Failed to start transaction %s" (Caqti_error.show msg));
          Lwt.return @@ Error msg
        | Ok () ->
          Logs.debug (fun m -> m "Started transaction");
          Lwt.catch
            (fun () ->
              let* result = f connection in
              let* commit_result = Connection.commit () in
              match commit_result with
              | Ok () ->
                Logs.debug (fun m -> m "Successfully committed transaction");
                Lwt.return @@ Ok result
              | Error error ->
                Logs.err (fun m ->
                    m "Failed to commit transaction %s" (Caqti_error.show error));
                Lwt.fail
                @@ Sihl_contract.Database.Exception
                     "Failed to commit transaction")
            (fun e ->
              let* rollback_result = Connection.rollback () in
              match rollback_result with
              | Ok () ->
                Logs.debug (fun m -> m "Successfully rolled back transaction");
                Lwt.fail e
              | Error error ->
                Logs.err (fun m ->
                    m
                      "Failed to rollback transaction %s"
                      (Caqti_error.show error));
                Lwt.fail
                @@ Sihl_contract.Database.Exception
                     "Failed to rollback transaction"))
      pool
  in
  match result with
  | Ok result -> Lwt.return result
  | Error error ->
    let msg = Caqti_error.show error in
    Logs.err (fun m -> m "%s" msg);
    Lwt.fail (Sihl_contract.Database.Exception msg)
;;

let query f =
  let pool = fetch_pool () in
  print_pool_usage pool;
  let* result =
    Caqti_lwt.Pool.use
      (fun connection -> f connection |> Lwt.map Result.ok)
      pool
  in
  match result with
  | Ok result -> Lwt.return result
  | Error error ->
    let msg = Caqti_error.show error in
    Logs.err (fun m -> m "%s" msg);
    Lwt.fail (Sihl_contract.Database.Exception msg)
;;

let used_database () =
  let host =
    (Core.Configuration.read schema).url |> Uri.of_string |> Uri.host
  in
  match host with
  | Some "mariadb" -> Some Sihl_contract.Database.MariaDb
  | Some "mysql" -> Some Sihl_contract.Database.MariaDb
  | Some "postgresql" -> Some Sihl_contract.Database.PostgreSql
  | Some not_supported ->
    Logs.warn (fun m -> m "Unsupported database %s found" not_supported);
    None
  | None -> None
;;

(* Service lifecycle *)

let start () =
  (* Make sure that configuration is valid *)
  Core.Configuration.require schema;
  (* Make sure that database is online when starting service. *)
  let _ = fetch_pool () in
  Lwt.return ()
;;

let stop () = Lwt.return ()

let lifecycle =
  Core.Container.Lifecycle.create Sihl_contract.Database.name ~start ~stop
;;

let register () =
  let configuration = Core.Configuration.make ~schema () in
  Core.Container.Service.create ~configuration lifecycle
;;
