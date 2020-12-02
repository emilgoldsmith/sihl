open Lwt.Syntax

module Migration =
  Sihl_persistence.Migration.Make (Sihl_persistence.Migration_repo.MariaDb)

module EmailTemplateRepo = Sihl_email.Template_repo.MakeMariaDb (Migration)
module EmailTemplateService = Sihl_email.Template.Make (EmailTemplateRepo)
module Email = Email.Make (EmailTemplateService)

let services =
  [ Sihl_persistence.Database.register ()
  ; Migration.register ()
  ; EmailTemplateService.register ()
  ]
;;

let () =
  Unix.putenv "DATABASE_URL" "mariadb://admin:password@127.0.0.1:3306/dev";
  Logs.set_level (Sihl_core.Log.get_log_level ());
  Logs.set_reporter (Sihl_core.Log.cli_reporter ());
  Lwt_main.run
    (let* _ = Sihl_core.Container.start_services services in
     let* () = Migration.run_all () in
     Alcotest_lwt.run "email mariadb" Email.suite)
;;
