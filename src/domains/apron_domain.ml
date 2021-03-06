open Apron
open Csp
open Apron_utils

module type ADomain = sig
  type t
  val get_manager: t Manager.t
end

(* Translation functor for syntax.prog to apron values*)
module SyntaxTranslator (D:ADomain) = struct
  let man = D.get_manager

  let rec expr_to_apron a (e:expr) : Texpr1.expr =
    let env = Abstract1.env a in
    match e with
    | Var v ->
      let var = Var.of_string v in
      if not (Environment.mem_var env var)
      then failwith ("variable not found: "^v);
      Texpr1.Var var
    | Cst c -> Texpr1.Cst (Coeff.s_of_float c)
    | Unary (o,e1) ->
      let r = match o with
	      | NEG -> Texpr1.Neg
	      | SQRT -> Texpr1.Sqrt
	      | COS | SIN | ABS -> failwith "COS and SIN unsupported with apron"
      in
      let e1 = expr_to_apron a e1 in
      Texpr1.Unop (r, e1, Texpr1.Real, Texpr1.Near)
    | Binary (o,e1,e2) ->
       let r = match o with
	       | ADD -> Texpr1.Add
	       | SUB -> Texpr1.Sub
	       | DIV -> Texpr1.Div
	       | MUL -> Texpr1.Mul
	       | POW -> Texpr1.Pow
       in
       let e1 = expr_to_apron a e1
       and e2 = expr_to_apron a e2 in
       Texpr1.Binop (r, e1, e2, Texpr1.Real, Texpr1.Near)

  let cmp_expr_to_apron b env =
    let cmp_to_apron (e1,op,e2) =
      match op with
      | EQ  -> e1, e2, Tcons1.EQ
      | NEQ -> e1, e2, Tcons1.DISEQ
      | GEQ -> e1, e2, Tcons1.SUPEQ
      | GT  -> e1, e2, Tcons1.SUP
      | LEQ -> e2, e1, Tcons1.SUPEQ
      | LT  -> e2, e1, Tcons1.SUP
    in
    let e1,e2,op = cmp_to_apron b in
    let e = Binary (SUB, e1, e2) in
    let a = Abstract1.top man env in
    let e = Texpr1.of_expr env (expr_to_apron a e) in
    let res = Tcons1.make e op in
    res
end


(*****************************************************************)
(* Some types and values that all the domains of apron can share *)
(* These are generic and can be redefined in the actuals domains *)
(*****************************************************************)
module MAKE(AP:ADomain) = struct

  module A = Abstract1

  type t = AP.t A.t

  let man = AP.get_manager

  module T = SyntaxTranslator(AP)

  let empty = A.top man (Environment.make [||] [||])

  let add_var abs (typ,v) =
    let e = A.env abs in
    let ints,reals = if typ = INT then [|Var.of_string v|],[||] else [||],[|Var.of_string v|] in
    let env = Environment.add e ints reals in
    A.change_environment man abs env false

  let is_bottom b = A.is_bottom man b

  let is_singleton b v =
    let man = A.manager b in
    if A.is_bottom man b then true
    else
      let itv = A.bound_variable man b v  in
      diam_interval itv |> Mpqf.to_float = 0.

  let is_enumerated abs =
    let int_vars = Environment.vars (A.env abs) |> fst in
    try
      Array.iter (fun v -> if (is_singleton abs v) |> not then raise Exit) int_vars;
      true
    with Exit -> false

  let join a b = A.join man a b

  let prune a b =
    let env = A.env a in
    let constr_to_earray c =
      let ear = Lincons1.array_make env 1 in
      Lincons1.array_set ear 0 c;
      ear
    in
    let rec aux a sures = function
      | [] -> sures
      | h::tl ->
	       let neg_h = neg_lincons h in
	       let neg_earray = constr_to_earray neg_h and h_earray = constr_to_earray h in
	       let a = A.meet_lincons_array man a h_earray
	       and s = A.meet_lincons_array man a neg_earray in
	       if is_bottom s then aux a sures tl
	       else aux a (s::sures) tl
    in
    let sures = aux a [] (A.to_lincons_array man b |> lincons_earray_to_list) in
    sures,b

  let filter b (e1,c,e2) =
    let env = A.env b in
    let c = T.cmp_expr_to_apron (e1,c,e2) env in
    A.meet_tcons_array man b (tcons_list_to_earray [c])

  let print = A.print

  let to_box abs env =
    let abs' = A.change_environment man abs env false in
    A.to_lincons_array man abs' |>
    A.of_lincons_array (Box.manager_alloc ()) env

  let to_oct abs env =
    let abs' = A.change_environment man abs env false in
    A.to_lincons_array man abs' |>
    A.of_lincons_array (Oct.manager_alloc ()) env

  let to_poly abs env =
    let abs' = A.change_environment man abs env false in
    A.to_lincons_array man abs' |>
    A.of_lincons_array (Polka.manager_alloc_strict ()) env

  (* given two variables to draw, and an environnement,
     returns the two variables value in the environment.
  *)
  let get_indexes env (x,y) =
	  (Environment.dim_of_var env (Var.of_string x)),
	  (Environment.dim_of_var env (Var.of_string y))

  let vertices2d abs (v1,v2) =
    let env = A.env abs in
    let draw_pol pol =
      let i1,i2 = get_indexes env (v1,v2) in
      let x = Environment.var_of_dim env i1
      and y = Environment.var_of_dim env i2 in
      let get_coord l = (Linexpr1.get_coeff l x),(Linexpr1.get_coeff l y) in
      let gen' = A.to_generator_array (Polka.manager_alloc_strict ()) pol in
      let v = Array.init (Generator1.array_length gen')
	(fun i -> get_coord
	  (Generator1.get_linexpr1 (Generator1.array_get gen' i)))
	       |> Array.to_list
      in
      List.map (fun(a,b)-> (coeff_to_float a, coeff_to_float b)) v
    in
    draw_pol (to_poly abs env)

  let vertices3d abs (v1,v2,v3) = failwith "no 3d generation for apron modules for now"

  let forward_eval abs cons =
    let ap_expr = T.expr_to_apron abs cons |> Texpr1.of_expr (A.env abs) in
    let obj_itv = A.bound_texpr man abs ap_expr in
    let obj_inf = obj_itv.Interval.inf
    and obj_sup = obj_itv.Interval.sup in
    (scalar_to_float obj_inf, scalar_to_float obj_sup)

    (* utilties for splitting *)

  let rec largest tab i max i_max =
    if i>=Array.length tab then (max, i_max)
    else
	    let dim = diam_interval (tab.(i)) in
	    if Mpqf.cmp dim max > 0 then largest tab (i+1) dim i
	    else largest tab (i+1) max i_max

  let largest abs : (Var.t * Interval.t * Mpqf.t) =
      let env = A.env abs in
      let box = A.to_box man abs in
      let tab = box.A.interval_array in
      let rec aux cur i_max diam_max itv_max =
	      if cur>=Array.length tab then (i_max, diam_max, itv_max)
	      else
	        let e = tab.(cur) in
	        let diam = diam_interval e in
	        if Mpqf.cmp diam diam_max > 0 then aux (cur+1) cur diam e
	        else aux (cur+1) i_max diam_max itv_max
      in
      let (a,b,c) = aux 0 0 (Mpqf.of_int 0) tab.(0) in
      ((Environment.var_of_dim env a),c,b)

    (* Compute the minimal and the maximal diameter of an array on intervals *)
    let rec minmax tab i max i_max min i_min =
      if i>=Array.length tab then  (max, i_max, min, i_min)
      else
	let dim = diam_interval (tab.(i)) in
	if Mpqf.cmp dim max > 0 then minmax tab (i+1) dim i min i_min
	else if Mpqf.cmp min dim > 0 then minmax tab (i+1) max i_max dim i
	else minmax tab (i+1) max i_max min i_min

    (* let p1 = (p11, p12, ..., p1n) and p2 = (p21, p22, ..., p2n) two points
     * The vector p1p2 is (p21-p11, p22-p12, ..., p2n-p1n) and the orthogonal line
     * to the vector p1p2 passing by the center of the vector has for equation:
     * (p21-p11)(x1-b1) + (p22-p12)(x2-b2) + ... + (p2n-p1n)(xn-bn) = 0
     * with b = ((p11+p21)/2, (p12+p22)/2, ..., (p1n+p2n)/2) *)
    let rec genere_linexpr gen_env size p1 p2 i list1 list2 cst =
      if i >= size then (list1, list2, cst) else
	let ci = p2.(i) -. p1.(i) in
	let cst' = cst +. ((p1.(i) +. p2.(i)) *. ci) in
	let ci' = 2. *. ci in
	let coeffi = Coeff.Scalar (Scalar.of_float ci') in
	let list1' = List.append list1 [(coeffi, Environment.var_of_dim gen_env i)] in
	let list2' = List.append list2 [(Coeff.neg coeffi, Environment.var_of_dim gen_env i)] in
	genere_linexpr gen_env size p1 p2 (i+1) list1' list2' cst'

 let split abs list =
    let meet_linexpr abs man env expr =
      let cons = Lincons1.make expr Lincons1.SUPEQ in
      let tab = Lincons1.array_make env 1 in
      Lincons1.array_set tab 0 cons;
      let abs' = A.meet_lincons_array man abs tab in
      abs'
    in
    let env = A.env abs in
    let abs1 = meet_linexpr abs man env (List.nth list 0) in
    let abs2 = meet_linexpr abs man env (List.nth list 1) in
    [abs1; abs2]

  (************************************************)
  (* POLYHEDRIC VERSION OF SOME USEFUL OPERATIONS *)
  (************************************************)

  let get_expr man polyad =
    let poly = A.to_generator_array man polyad in
    let gen_env = poly.Generator1.array_env in
    (*print_gen gens gen_env;*)
    let size = Environment.size gen_env in
    let gen_float_array = gen_to_array poly size in
    let (p1, i1, p2, i2, dist_max) = maxdisttab gen_float_array in
    let (list1, list2, cst) = genere_linexpr gen_env size p1 p2 0 [] [] 0. in
    let cst_sca1 = Scalar.of_float (-1. *.(cst +. split_prec)) in
    let cst_sca2 = Scalar.of_float (cst +. split_prec) in
    let linexp = Linexpr1.make gen_env in
    Linexpr1.set_list linexp list1 (Some (Coeff.Scalar cst_sca1));
    let linexp' = Linexpr1.make gen_env in
    Linexpr1.set_list linexp' list2 (Some (Coeff.Scalar cst_sca2));
    [linexp; linexp']

  let is_small man polyad =
    let poly = A.to_generator_array man polyad in
    let gen_env = poly.Generator1.array_env in
    (*print_gen gens gen_env;*)
    let size = Environment.size gen_env in
    let gen_float_array = gen_to_array poly size in
    let (p1, i1, p2, i2, dist_max) = maxdisttab gen_float_array in
    (dist_max <= !Constant.precision)
end
