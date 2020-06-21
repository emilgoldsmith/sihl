module type REPO = sig
  val migrate : unit -> Migration_model.Migration.t

  val clean : Core_db.connection -> unit Core_db.db_result
end
