
(*
   Types
 *)

(* type variables for polymorphism *)
(* We don't need these for now
module TyVar = Key.Make (struct let x="a" end)
type ty_var = TyVar.t
 *)

(* type labels *)
module TypeLabel = Key.Make (struct let x="ty" end)
type ty_label = TypeLabel.t

(* extension variables *)
module ExtVar = Key.Make (struct let x="ext" end)
type extvar = ExtVar.t

(* types for data pointers *)
module DataTy = Key.Make (struct let x="d" end)

(* type parameter variables for extensible arrow types *)
module TyParamsLabel = Key.Make (struct let x="p" end)
type ty_params_label = TyParamsLabel.t

(* type datatype *)
type ty = (* TyArrow of ty_label list * ty_label *)
  | TyInt
  | TyBool
  | TyList of ty_label
  | TyArrow of (ty_label list) * ty_label
  | TyArrowExt of ty_params_label * ty_label
  (* | TyVar of ty_var *)
(*type ty_node = {ty : ty}*)

(* type tree datatype *)
type flat_ty =
  | FlatTyInt
  | FlatTyBool
  | FlatTyList of flat_ty
  | FlatTyArrow of (flat_ty list) * flat_ty
  | FlatTyVar of string


type registry = {
    (* type operations *)
    new_ty : ty -> ty_label;
    get_ty : ty_label -> ty;

    (* extension variable operations *)
    new_extvar : unit -> extvar;

    (* type parameter operations *)
    new_ty_params : extvar -> ty_params_label;
    get_ty_params : ty_params_label -> ty_label list;
    add_ty_param : ty_params_label -> ty_label -> unit;

    (* all params labels that are associated with the given extvar *)
    extvar_ty_params : extvar -> ty_params_label list;
    ty_params_extvar : ty_params_label -> extvar;

    flat_ty_to_ty : flat_ty -> ty_label;
  }

exception BadTypeError of string
let flat_ty_to_ty new_ty =
  let rec lp ty = 
    let ty' = match ty with
      | FlatTyVar _ -> raise (BadTypeError "Cannot generate polymorphic types")
      | FlatTyInt -> TyInt
      | FlatTyBool -> TyBool
      | FlatTyList ty'' -> TyList (lp ty'')
      | FlatTyArrow (params, res) -> TyArrow (List.rev_map lp params, lp res) in
    new_ty ty'
  in lp 

let make () (*?(std_lib = [])*) =
  let ty_tbl : ty TypeLabel.Tbl.t = TypeLabel.Tbl.create 100 in
  let ty_params_tbl : (ty_label list) TyParamsLabel.Tbl.t = TyParamsLabel.Tbl.create 100 in
  let extvar_ty_params_tbl : (ty_params_label list) ExtVar.Tbl.t = ExtVar.Tbl.create 100 in
  let ty_params_extvar_tbl : extvar TyParamsLabel.Tbl.t = TyParamsLabel.Tbl.create 100 in

  let new_extvar () =
    let extvar = ExtVar.make () in
    ExtVar.Tbl.add extvar_ty_params_tbl extvar [];
    extvar in

  let new_ty =
    let bool_lab = TypeLabel.make () in
    TypeLabel.Tbl.add ty_tbl bool_lab TyBool;
    let int_lab = TypeLabel.make () in
    TypeLabel.Tbl.add ty_tbl int_lab TyInt;
    fun ty' ->
      match ty' with
      | TyBool -> bool_lab
      | TyInt -> int_lab
      | _ ->
        let lab = TypeLabel.make () in
        TypeLabel.Tbl.add ty_tbl lab ty';
        lab in
  let get_ty lab = TypeLabel.Tbl.find ty_tbl lab in

  let new_ty_params extvar =
    let lab = TyParamsLabel.make() in
    TyParamsLabel.Tbl.add ty_params_tbl lab [];
    ExtVar.Tbl.replace extvar_ty_params_tbl extvar
                       (lab :: (ExtVar.Tbl.find extvar_ty_params_tbl extvar));
    TyParamsLabel.Tbl.add ty_params_extvar_tbl lab extvar;
    lab in
  let get_ty_params lab = TyParamsLabel.Tbl.find ty_params_tbl lab in
  let add_ty_param lab ty =
    TyParamsLabel.Tbl.replace ty_params_tbl lab
                              (ty :: (TyParamsLabel.Tbl.find ty_params_tbl lab));
    () in
  let extvar_ty_params extvar = ExtVar.Tbl.find extvar_ty_params_tbl extvar in
  let ty_params_extvar lab = TyParamsLabel.Tbl.find ty_params_extvar_tbl lab in

  {
    new_extvar = new_extvar;
    new_ty = new_ty;
    get_ty = get_ty;

    new_ty_params = new_ty_params;
    get_ty_params = get_ty_params;
    add_ty_param = add_ty_param;

    extvar_ty_params = extvar_ty_params;
    ty_params_extvar = ty_params_extvar;

    flat_ty_to_ty = flat_ty_to_ty new_ty;
  }

