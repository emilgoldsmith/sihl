open Base

let ( let* ) = Lwt.bind

let request_with_connection () =
  "/mocked-request" |> Uri.of_string |> Cohttp_lwt.Request.make
  |> Opium.Std.Request.create |> Core.Db.request_with_connection

let seed seed_fn =
  let* request = request_with_connection () in
  seed_fn request

let register_services services =
  let config =
    Core.Config.Setting.create ~development:[]
      ~test:[ ("DATABASE_URL", "mariadb://admin:password@127.0.0.1:3306/dev") ]
      ~production:[]
  in
  let project = Run.Project.Project.create ~services ~config [] [] in
  let* result = Run.Project.Project.start project in
  let () = result |> Result.ok_or_failwith in
  let* result = Run.Project.Project.clean project in
  result |> Result.ok_or_failwith |> Lwt.return
