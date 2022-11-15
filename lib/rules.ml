
(* FIXME *)
exception InternalError of string


type hole_info = {
    label : Exp.exp_label;
    ty_label : Exp.ty_label;
    prev : Exp.exp_label option;
    fuel : int;
    vars : (Exp.var * Exp.ty_label) list;
    depth : int;
  }

(* BEGIN UTILS *)
(* FIXME: move some into exp.ml? *)

let rec find_pos (prog : Exp.program) (e : Exp.exp_label) (height : int) =
  if height == 0
  then e
  else match (prog.get_exp e).prev with
       | None -> e
       | Some e' -> find_pos prog e' (height - 1)

(* TODO: pass full list of in-scope variables here *)
let rec generate_type size (prog : Exp.program) =
  prog.new_ty
    ((Choose.choose_frequency
        [(1, (fun _ -> Exp.TyNdBool)); (1, (fun _ -> Exp.TyNdInt));
         (size, (fun _ -> Exp.TyNdList (generate_type (size - 1) prog)))])
     ())

let rec ty_label_from_ty prog mp ty =
  match ty with
  | Exp.TyVar var ->
    (match List.assoc_opt var mp with
     | None -> let tyl = generate_type 3 prog in
               ((var, tyl) :: mp, tyl)
     | Some tyl -> (mp, tyl))
  | Exp.TyInt -> (mp, prog.new_ty Exp.TyNdInt)
  | Exp.TyBool -> (mp, prog.new_ty Exp.TyNdBool)
  | Exp.TyList ty' ->
    let (mp, tyl') = ty_label_from_ty prog mp ty' in
    (mp, prog.new_ty (Exp.TyNdList tyl'))
  | Exp.TyArrow (tys, ty') ->
    let (mp, tyl') = ty_label_from_ty prog mp ty' in
    let (mp, tys') = List.fold_left_map (ty_label_from_ty prog) mp (List.rev tys) in
    (mp, prog.new_ty (Exp.TyNdArrow (tys', tyl')))

(* TODO: use this again *)
let rec type_complexity (prog : Exp.program) (ty : Exp.ty_label) =
  match prog.get_ty ty with
  | Exp.TyNdBool -> 1
  | Exp.TyNdInt -> 1
  | Exp.TyNdList ty' -> 2 + type_complexity prog ty'
  | Exp.TyNdArrow (params, ty') ->
    List.fold_left
      (fun acc ty'' -> acc + type_complexity prog ty'')
      (1 + type_complexity prog ty')
      params
  | Exp.TyNdArrowExt (params, ty') ->
    List.fold_left
      (fun acc ty'' -> acc + type_complexity prog ty'')
      (1 + type_complexity prog ty')
      (prog.get_ty_params params)

(* END UTILS *)

(* FIXME: bring the weight functions out front *)


(* Implements the rule:
   E ~> E{alpha + tau}
 *)
let extend_extvar (prog : Exp.program) (extvar : Exp.extvar) (ext_ty : Exp.ty_label) =
  let extend : 'a 'b . Exp.extvar -> (Exp.extvar -> 'a list) -> ('a -> unit) -> unit =
    fun ext get add ->
    let lst = get ext in
    let handle_elt elt = add elt in
    List.iter handle_elt lst in

  extend extvar prog.extvar_ty_params
         (fun ty_params -> prog.add_ty_param ty_params ext_ty);
  extend extvar prog.extvar_params
         (fun param -> prog.add_param param (prog.new_var()));

  (* Justin: there has to be a better way... *)
  (* Ben: no *)
  let exp_lbls = ref [] in
  extend extvar prog.extvar_args
         (fun arg ->
          let app_lbl = prog.args_parent arg in
          let exp_lbl = prog.new_exp {exp=Exp.Hole; ty=ext_ty; prev=Some app_lbl} in
          prog.add_arg arg exp_lbl;
          exp_lbls := exp_lbl :: !exp_lbls);

  !exp_lbls


(* Implements the rule:
   E_1[lambda_i xs alpha . E_2[<>]] ~>
   E_1{alpha + tau}[lambda_i (x::xs) alpha . E_2{alpha + tau}[x]]

   via the decomposition

   E_1[lambda_i xs alpha . E_2[<>]] ~>
   E_1{alpha + tau}[lambda_i (x::xs) alpha . E_2{alpha+tau}[<>]] ~>
   E_1{alpha + tau}[lambda_i (x::xs) alpha . E_2{alpha + tau}[x]]
 *)
let not_useless_step (prog : Exp.program) (hole : hole_info) (weight : hole_info -> int) param =
    (weight hole,
     fun () ->
       Printf.eprintf ("extending ext. var\n");
       let extvar = prog.params_extvar param in
       let holes = extend_extvar prog extvar hole.ty_label in
       let x = List.hd (prog.get_params param) in
       prog.set_exp hole.label {exp=Exp.Var x; ty=hole.ty_label; prev=hole.prev};
       holes)


(* Implements the rule:
   E[<>] ~> E[call <> alpha] where alpha is fresh
 *)
let ext_function_call_steps (weight : hole_info -> int) (prog : Exp.program) (hole : hole_info)  =
  (weight hole,
    fun () ->
      Printf.eprintf ("creating ext. function call\n");
      let extvar = prog.new_extvar() in
      let f_ty = prog.new_ty (Exp.TyNdArrowExt (prog.new_ty_params extvar, hole.ty_label)) in
      let f = prog.new_exp {exp=Exp.Hole; ty=f_ty; prev=Some hole.label} in
      let args = prog.new_args extvar hole.label in
      prog.set_exp hole.label {exp=Exp.ExtCall (f, args); ty=hole.ty_label; prev=hole.prev};
      [f])



(* Implements the rule:
   E[<>] ~> E[call f <> ... alpha] where f is in alpha
 *)
let palka_rule_step (prog : Exp.program) (hole : hole_info) (weight : hole_info -> int) (f, f_ty) =
    (weight hole,
     fun () ->
       Printf.eprintf ("creating palka function call\n");
       let fe = prog.new_exp {exp=Exp.Var f; ty=f_ty; prev=Some hole.label} in
       match (prog.get_ty f_ty) with
       | Exp.TyNdArrowExt (ty_params, _) ->
         let extvar = prog.ty_params_extvar ty_params in
         let args = prog.new_args extvar hole.label in
         let holes = List.map (fun arg_ty ->
                                 let hole = prog.new_exp {exp=Exp.Hole; ty=arg_ty; prev=Some hole.label} in
                                 prog.add_arg args hole;
                                 hole)
                              (List.rev (prog.get_ty_params ty_params)) in
         prog.set_exp hole.label {exp=Exp.ExtCall (fe, args); ty=hole.ty_label; prev=hole.prev};
         holes
       | Exp.TyNdArrow (tys, _) ->
         let holes = List.map (fun arg_ty -> prog.new_exp {exp=Exp.Hole; ty=arg_ty; prev=Some hole.label}) tys in
         prog.set_exp hole.label {exp=Exp.Call (fe, holes); ty=hole.ty_label; prev=hole.prev};
         holes
       | _ -> raise (InternalError "variable in function list not a function"))


(* Implements the rule:
   FIXME
   E[<>] ~> 
 *)
let let_insertion_step (prog : Exp.program) (hole : hole_info) (weight : hole_info -> int) height =
  (weight hole,
   fun () ->
   Printf.eprintf ("inserting let\n");
   let e' = find_pos prog hole.label height in
   let node' = prog.get_exp e' in
   let x = prog.new_var () in
   let e_let = prog.new_exp {exp=Exp.Hole; ty=node'.ty; prev=node'.prev} in
   let e_hole = prog.new_exp {exp=Exp.Hole; ty=hole.ty_label; prev=Some e_let} in
   prog.set_exp e_let {exp=Exp.Let (x, e_hole, e'); ty=node'.ty; prev=node'.prev};
   prog.set_exp e' {exp=node'.exp; ty=node'.ty; prev=Some e_let};
   (match node'.prev with
    | None -> prog.head <- e_let
    | Some e'' -> prog.rename_child (e', e_let) e'');
   let node = prog.get_exp hole.label in
   prog.set_exp hole.label {exp=Exp.Var x; ty=node.ty; prev=node.prev};
   [e_hole])


(* TODO: reduce redundancy *)
(* Implements the rule:
   FIXME
   E[<>] ~> 
 *)
let match_insertion_step (prog : Exp.program) (hole : hole_info) (weight : hole_info -> int) height =
  (weight hole,
   fun () ->
   Printf.eprintf ("inserting match (fst)\n");
   let e' = find_pos prog hole.label height in
   let node' = prog.get_exp e' in
   let e_match = prog.new_exp {exp=Exp.Hole; ty=node'.ty; prev=node'.prev} in
   let hole_nil = prog.new_exp {exp=Exp.Hole; ty=node'.ty; prev=Some e_match} in
   let list_ty = prog.new_ty (Exp.TyNdList hole.ty_label) in
   let hole_scr = prog.new_exp {exp=Exp.Hole; ty=list_ty; prev=Some e_match} in
   let x = prog.new_var () in
   let y = prog.new_var () in
   prog.set_exp e_match {exp=Exp.Match (hole_scr, hole_nil, (x, y, e')); ty=node'.ty; prev=node'.prev};
   prog.set_exp e' {exp=node'.exp; ty=node'.ty; prev=Some e_match};
   (match node'.prev with
    | None -> prog.head <- e_match
    | Some e'' -> prog.rename_child (e', e_match) e'');
   let node = prog.get_exp hole.label in
   prog.set_exp hole.label {exp=Exp.Var x; ty=node.ty; prev=node.prev};
   [hole_scr; hole_nil])

(* Implements the rule:
   FIXME
   E[<>] ~> 
 *)
let match_insertion_list_step (prog : Exp.program) (hole : hole_info) (weight : hole_info -> int) height =
  (weight hole,
   fun () ->
   Printf.eprintf ("inserting match (rst)\n");
   let e' = find_pos prog hole.label height in
   let node' = prog.get_exp e' in
   let e_match = prog.new_exp {exp=Exp.Hole; ty=node'.ty; prev=node'.prev} in
   let hole_nil = prog.new_exp {exp=Exp.Hole; ty=node'.ty; prev=Some e_match} in
   let hole_scr = prog.new_exp {exp=Exp.Hole; ty=hole.ty_label; prev=Some e_match} in
   let x = prog.new_var () in
   let y = prog.new_var () in
   prog.set_exp e_match {exp=Exp.Match (hole_scr, hole_nil, (x, y, e')); ty=node'.ty; prev=node'.prev};
   prog.set_exp e' {exp=node'.exp; ty=node'.ty; prev=Some e_match};
   (match node'.prev with
    | None -> prog.head <- e_match
    | Some e'' -> prog.rename_child (e', e_match) e'');
   let node = prog.get_exp hole.label in
   prog.set_exp hole.label {exp=Exp.Var y; ty=node.ty; prev=node.prev};
   [hole_scr; hole_nil])


(* Implements the rule:
   FIXME
   E[<>] ~> 
 *)
let create_match_step (prog : Exp.program) (hole : hole_info) (weight : hole_info -> int) (x, ty) =
  (weight hole,
   fun () ->
   Printf.eprintf ("creating match\n");
   let e_scr = prog.new_exp {exp=Exp.Var x; ty=ty; prev=Some hole.label} in
   let e_empty = prog.new_exp {exp=Exp.Hole; ty=hole.ty_label; prev=Some hole.label} in
   let e_cons = prog.new_exp {exp=Exp.Hole; ty=hole.ty_label; prev=Some hole.label} in
   prog.set_exp hole.label
                {exp=Exp.Match (e_scr, e_empty, (prog.new_var (), prog.new_var (), e_cons));
                 ty=hole.ty_label; prev=hole.prev};
   [e_empty; e_cons])



(* Implements the rule:
   E[<>] ~> E[x]
 *)
(* TODO: increase the chance of variable reference for complex types? *)
let var_step (prog : Exp.program) (hole : hole_info) (weight : hole_info -> int) (var, _) =
  (weight(hole),
   fun () ->
      Printf.eprintf ("creating var reference\n");
      prog.set_exp hole.label {exp=Exp.Var var; ty=hole.ty_label; prev=hole.prev};
      [])


(* Implements the rule:
   FIXME
   E[<>] ~> 
 *)
let create_if_steps (weight : hole_info -> int) (prog : Exp.program) (hole : hole_info)  =
  (weight(hole),
    fun () ->
      Printf.eprintf ("creating if\n");
      let pred = prog.new_exp {exp=Exp.Hole; ty=prog.new_ty Exp.TyNdBool; prev=Some hole.label} in
      let thn = prog.new_exp {exp=Exp.Hole; ty=hole.ty_label; prev=Some hole.label} in
      let els = prog.new_exp {exp=Exp.Hole; ty=hole.ty_label; prev=Some hole.label} in
      prog.set_exp hole.label {exp=Exp.If (pred, thn, els); ty=hole.ty_label; prev=hole.prev};
      [pred; thn; els])



(* Implements the rule:
   FIXME
   E[<>] ~> 
 *)
let std_lib_step (weight : hole_info -> int) (prog : Exp.program) (hole : hole_info) x =
  (weight(hole), (* TODO: incorporate occurence amount here *)
   fun () ->
   Printf.eprintf ("creating std lib reference: %s\n") x;
   prog.set_exp hole.label {exp=Exp.StdLibRef x; ty=hole.ty_label; prev=hole.prev};
   [])


(* Implements the rule:
   FIXME
   E[<>] ~> 
 *)
let std_lib_palka_rule_step (weight : hole_info -> int) (prog : Exp.program) (hole : hole_info) (f, tys, mp) =
  (weight hole, (* TODO: incorporate occurence amount here *)
   fun () ->
   Printf.eprintf ("creating std lib palka call: %s\n") f;
   let (_, tyls) = List.fold_left_map (ty_label_from_ty prog) mp (List.rev tys) in
   let holes = List.map (fun tyl -> prog.new_exp {exp=Exp.Hole; ty=tyl; prev=Some hole.label}) tyls in
   let func = prog.new_exp {exp=Exp.StdLibRef f; ty=prog.new_ty (Exp.TyNdArrow (tyls, hole.ty_label)); prev=Some hole.label} in
   prog.set_exp hole.label {exp=Exp.Call (func, holes); ty=hole.ty_label; prev=hole.prev};
   holes)


