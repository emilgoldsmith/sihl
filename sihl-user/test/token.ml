open Lwt.Syntax
open Alcotest_lwt

let token = Alcotest.testable Sihl_contract.Token.pp Sihl_contract.Token.equal

module Make (TokenService : Sihl_contract.Token.Sig) = struct
  let create_and_find_token _ () =
    let* () = Sihl_core.Cleaner.clean_all () in
    let* created = TokenService.create ~kind:"test" ~data:"foo" () in
    let created_value = Sihl_contract.Token.value created in
    let* found = TokenService.find created_value in
    let () = Alcotest.(check token "Has created session" created found) in
    Lwt.return ()
  ;;

  let suite =
    [ "token", [ test_case "create and find token" `Quick create_and_find_token ] ]
  ;;
end
