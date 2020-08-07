(* This file is part of the Catala compiler, a specification language for tax and social benefits
   computation rules. Copyright (C) 2020 Inria, contributor: Nicolas Chataing
   <nicolas.chataing@ens.fr>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
   in compliance with the License. You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software distributed under the License
   is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
   or implied. See the License for the specific language governing permissions and limitations under
   the License. *)

open Ast
open Lambda

let subscope_ident (y : string) (x : string) : string = y ^ "::" ^ x

(** The optional argument subdef allows to choose between differents uids in case the expression is
    a redefinition of a subvariable *)
let rec expr_to_lambda ?(subdef : Uid.t option) (scope : Uid.t) (ctxt : Context.context)
    ((expr, pos) : Ast.expression Pos.marked) : Lambda.term =
  let rec_helper = expr_to_lambda ?subdef scope ctxt in
  match expr with
  | IfThenElse (e_if, e_then, e_else) ->
      ((EIfThenElse (rec_helper e_if, rec_helper e_then, rec_helper e_else), pos), TDummy)
  | Binop (op, e1, e2) ->
      let op_term = (Pos.same_pos_as (EOp (Binop (Pos.unmark op))) op, TDummy) in
      ((EApp (op_term, [ rec_helper e1; rec_helper e2 ]), pos), TDummy)
  | Unop (op, e) ->
      let op_term = (Pos.same_pos_as (EOp (Unop (Pos.unmark op))) op, TDummy) in
      ((EApp (op_term, [ rec_helper e ]), pos), TDummy)
  | Literal l ->
      let untyped_term =
        match l with
        | Number ((Int i, _), _) -> EInt i
        | Number ((Dec (i, f), _), _) -> EDec (i, f)
        | Bool b -> EBool b
        | _ -> assert false
      in
      ((untyped_term, pos), TDummy)
  | Ident x ->
      let uid = Context.get_var_uid scope ctxt (x, pos) in
      ((EVar uid, pos), TDummy)
  | Dotted (e, x) -> (
      (* For now we only accept dotted identifiers of the type y.x where y is a sub-scope *)
      match Pos.unmark e with
      | Ident y -> (
          let _, sub_uid = Context.get_subscope_uid scope ctxt (Pos.same_pos_as y e) in
          match subdef with
          | None ->
              (* No redefinition : take the uid from the current scope *)
              let ident = subscope_ident y (Pos.unmark x) in
              let uid = Context.get_var_uid scope ctxt (ident, Pos.get_position e) in
              ((EVar uid, pos), TDummy)
          | Some uid when uid <> sub_uid ->
              (* Redefinition of a var from another scope : uid from the current scope *)
              let ident = subscope_ident y (Pos.unmark x) in
              let uid = Context.get_var_uid scope ctxt (ident, Pos.get_position e) in
              ((EVar uid, pos), TDummy)
          | Some sub_uid ->
              (* Redefinition of a var from the same scope, uid from the subscope *)
              let uid = Context.get_var_uid sub_uid ctxt x in
              ((EVar uid, pos), TDummy) )
      | _ -> assert false )
  | FunCall (f, arg) -> ((EApp (rec_helper f, [ rec_helper arg ]), pos), TDummy)
  | _ -> assert false

(** Checks that a term is well typed and annotate it *)
let rec typing (ctxt : Context.context) (((t, pos), _) : Lambda.term) : Lambda.term =
  match t with
  | EVar uid ->
      let typ = Context.get_uid_typ ctxt uid in
      ((EVar uid, pos), typ)
  | EFun (bindings, body) ->
      (* Note that given the context formation process, the binder will already be present in the
         context (since we are working with uids), however it's added there for the sake of clarity *)
      let ctxt_data =
        List.fold_left
          (fun data (uid, arg_typ) ->
            let uid_data : Context.uid_data = { uid_typ = arg_typ; uid_sort = Context.IdBinder } in
            Uid.UidMap.add uid uid_data data)
          ctxt.data bindings
      in

      let body = typing { ctxt with data = ctxt_data } body in
      let ret_typ = Lambda.get_typ body in
      let rec build_typ = function
        | [] -> ret_typ
        | (_, arg_t) :: args -> TArrow (arg_t, build_typ args)
      in
      let fun_typ = build_typ bindings in
      ((EFun (bindings, body), pos), fun_typ)
  | EApp (f, args) ->
      let f = typing ctxt f in
      let f_typ = Lambda.get_typ f in
      let args = List.map (typing ctxt) args in
      let args_typ = List.map Lambda.get_typ args in
      let rec check_arrow_typ f_typ args_typ =
        match (f_typ, args_typ) with
        | typ, [] -> typ
        | TArrow (arg_typ, ret_typ), fst_typ :: typs ->
            if arg_typ = fst_typ then check_arrow_typ ret_typ typs else assert false
        | _ -> assert false
      in
      let ret_typ = check_arrow_typ f_typ args_typ in
      ((EApp (f, args), pos), ret_typ)
  | EIfThenElse (t_if, t_then, t_else) ->
      let t_if = typing ctxt t_if in
      let typ_if = Lambda.get_typ t_if in
      let t_then = typing ctxt t_then in
      let typ_then = Lambda.get_typ t_then in
      let t_else = typing ctxt t_else in
      let typ_else = Lambda.get_typ t_else in
      if typ_if <> TBool then assert false
      else if typ_then <> typ_else then assert false
      else ((EIfThenElse (t_if, t_then, t_else), pos), typ_then)
  | EInt _ | EDec _ -> ((t, pos), TInt)
  | EBool _ -> ((t, pos), TBool)
  | EOp op ->
      let typ =
        match op with
        | Binop binop -> (
            match binop with
            | And | Or -> TArrow (TBool, TArrow (TBool, TBool))
            | Add | Sub | Mult | Div -> TArrow (TInt, TArrow (TInt, TInt))
            | Lt | Lte | Gt | Gte | Eq | Neq -> TArrow (TInt, TArrow (TInt, TBool)) )
        | Unop Minus -> TArrow (TInt, TInt)
        | Unop Not -> TArrow (TBool, TBool)
      in
      ((t, pos), typ)
  | EDefault t ->
      let defaults =
        IntMap.map
          (fun (just, cons) ->
            let just = typing ctxt just in
            if Lambda.get_typ just <> TBool then
              let cons = typing ctxt cons in
              (just, cons)
            else assert false)
          t.defaults
      in
      let typ_cons = IntMap.choose defaults |> snd |> snd |> Lambda.get_typ in
      IntMap.iter
        (fun _ (_, cons) -> if Lambda.get_typ cons <> typ_cons then assert false else ())
        defaults;
      ((EDefault { t with defaults }, pos), typ_cons)

(* Translation from the parsed ast to the scope language *)

let merge_conditions (precond : Lambda.term option) (cond : Lambda.term option)
    (default_pos : Pos.t) : Lambda.term =
  match (precond, cond) with
  | Some precond, Some cond ->
      let op_term = ((EOp (Binop And), Pos.get_position (fst precond)), TDummy) in
      ((EApp (op_term, [ precond; cond ]), Pos.get_position (fst precond)), TDummy)
  | Some cond, None | None, Some cond -> cond
  | None, None -> ((EBool true, default_pos), TBool)

let process_default (ctxt : Context.context) (scope : Uid.t) (def : Lambda.default_term)
    (precond : Lambda.term option) (just : Ast.expression Pos.marked option)
    (body : Ast.expression Pos.marked) (subdef : Uid.t option) : Lambda.default_term =
  let just =
    match just with
    | Some cond ->
        let cond = expr_to_lambda ?subdef scope ctxt cond |> typing ctxt in
        if Lambda.get_typ cond = TBool then Some cond else assert false
    | None -> None
  in
  let condition = merge_conditions precond just (Pos.get_position body) |> typing ctxt in
  let body = expr_to_lambda ?subdef scope ctxt body |> typing ctxt in
  Lambda.add_default condition body def

(* Process a definition *)
let process_def (_precond : Lambda.term option) (_scope : Uid.t) (_ctxt : Context.context)
    (_prgm : Scope.program) (_def : Ast.definition) : Scope.program =
  assert false

(** Process a rule from the surface language *)
let process_rule (precond : Lambda.term option) (scope : Uid.t) (ctxt : Context.context)
    (prgm : Scope.program) (rule : Ast.rule) : Scope.program =
  let consequence_expr = Ast.Literal (Ast.Bool (Pos.unmark rule.rule_consequence)) in
  let def =
    {
      definition_name = rule.rule_name;
      definition_parameter = rule.rule_parameter;
      definition_condition = rule.rule_condition;
      definition_expr = (consequence_expr, Pos.get_position rule.rule_consequence);
    }
  in
  process_def precond scope ctxt prgm def

let process_scope_use_item (cond : Lambda.term option) (scope : Uid.t) (ctxt : Context.context)
    (prgm : Scope.program) (item : Ast.scope_use_item Pos.marked) : Scope.program =
  match Pos.unmark item with
  | Ast.Rule rule -> process_rule cond scope ctxt prgm rule
  | Ast.Definition def -> process_def cond scope ctxt prgm def
  | _ -> prgm

let process_scope_use (ctxt : Context.context) (prgm : Scope.program) (use : Ast.scope_use) :
    Scope.program =
  let name = fst use.scope_use_name in
  let scope_uid = Context.IdentMap.find name ctxt.scope_id_to_uid in
  (* Make sure the scope exists *)
  let prgm =
    match UidMap.find_opt scope_uid prgm with
    | Some _ -> prgm
    | None -> UidMap.add scope_uid (Scope.empty_scope scope_uid) prgm
  in
  let cond =
    match use.scope_use_condition with
    | Some expr ->
        let untyped_term = expr_to_lambda scope_uid ctxt expr in
        let term = typing ctxt untyped_term in
        if Lambda.get_typ term = TBool then Some term else assert false
    | None -> None
  in
  List.fold_left (process_scope_use_item cond scope_uid ctxt) prgm use.scope_use_items

(** Scopes processing *)
let translate_program_to_scope (ctxt : Context.context) (prgm : Ast.program) : Scope.program =
  let empty_prgm = UidMap.empty in
  let processer (prgm : Scope.program) (item : Ast.program_item) : Scope.program =
    match item with
    | CodeBlock (block, _) | MetadataBlock (block, _) ->
        List.fold_left
          (fun prgm item ->
            match Pos.unmark item with ScopeUse use -> process_scope_use ctxt prgm use | _ -> prgm)
          prgm block
    | _ -> prgm
  in
  List.fold_left processer empty_prgm prgm.program_items
