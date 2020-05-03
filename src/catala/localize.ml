(* This file is part of the Catala compiler, a specification language for tax and social benefits
   computation rules. Copyright (C) 2020 Inria, contributor: Denis Merigoux
   <denis.merigoux@inria.fr>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
   in compliance with the License. You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software distributed under the License
   is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
   or implied. See the License for the specific language governing permissions and limitations under
   the License. *)

module Translate =
  Gettext.Program
    (struct
      let textdomain = "catala"

      let codeset = Some "UTF-8"

      let dir = None

      let dependencies = Gettext.init
    end)
    (GettextCamomile.Map)

let set_locale_dir (locale_dir : string option) : unit =
  let args, _ = Translate.init in
  List.iter
    (fun arg ->
      let key, spec, _ = arg in
      ( if key = "--gettext-dir" then
        match spec with
        | Arg.String set_locale_dir -> (
            match locale_dir with Some s -> set_locale_dir s | None -> () )
        | _ -> assert false (* should not happen *) );
      if key = "--gettext-failsafe" then
        match spec with
        | Arg.Symbol (_, set_failsafe) -> set_failsafe "inform-stderr"
        | _ -> assert false
      (* should not happen *))
    args
