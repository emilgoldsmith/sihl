let config =
  Sihl.Core.Config.Setting.create ~development:[]
    ~test:
      [
        ("BASE_URL", "http://localhost:3000");
        ("DATABASE_URL", "postgres://admin:password@127.0.0.1:5432/dev");
      ]
    ~production:[]

let middlewares =
  [ Sihl.Middleware.db; Sihl.Middleware.cookie; Sihl_session.middleware ]

let services = [ Sihl_session_postgresql.bind; Sihl.Migration.postgresql ]

let project =
  Sihl.Run.Project.Project.create ~config ~services middlewares
    [ (module Sihl_session.App) ]

let () = Sihl.Run.Project.Project.run_command project
