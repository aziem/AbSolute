open Adcp_sig

(* Boolean expressions abstractions *)
module Boolean (Abs:AbstractCP) = struct

  let rec filter (value:Abs.t) = let open Csp in function
    | And (b1,b2) -> filter (filter value b2) b1
    | Or (b1,b2) ->
      let a1 = try Some(filter value b1) with Bot.Bot_found -> None
      and a2 = try Some(filter value b2) with Bot.Bot_found -> None in
      (match (a1,a2) with
      | (Some a1),(Some a2) -> Abs.join a1 a2
      | None, (Some x) | (Some x), None -> x
      | _ -> raise Bot.Bot_found)
    | Not b -> filter value (neg_bexpr b)
    | Cmp (binop,e1,e2) -> Abs.filter value (e1,binop,e2)


  let rec sat_cons (a:Abs.t) (constr:Csp.bexpr) : bool =
    let open Csp in
    match constr with
    | Or (b1,b2) -> sat_cons a b1 || sat_cons a b2
    | And (b1,b2) -> sat_cons a b1 && sat_cons a b2
    | Not b -> sat_cons a (neg_bexpr b)
    | _ ->
      try Abs.is_bottom (filter a (neg_bexpr constr))
      with Bot.Bot_found -> Abs.is_enumerated a
end

(* Consistency computation and splitting strategy handling *)
module Make (Abs : AbstractCP) = struct

  include Boolean(Abs)

  let init (problem:Csp.prog) : Abs.t =
    Csp.(List.fold_left (fun abs (t,v,d) ->
      let c1,c2 = domain_to_constraints (t,v,d) in
      let abs = Abs.add_var abs (t,v) in
      Abs.filter (Abs.filter abs c1) c2
    )  Abs.empty problem.init)

  type consistency = Full of Abs.t
		     | Maybe of Abs.t * Csp.bexpr list
		     | Empty

  let consistency abs constrs : consistency =
    try
      let abs' = List.fold_left filter abs constrs in
      if Abs.is_bottom abs' then Empty else
	let unsat = List.filter (fun c -> not (sat_cons abs' c)) constrs in
	match unsat with
	| [] -> Full abs'
	| _ -> if Abs.is_bottom abs' then Empty else Maybe(abs', unsat)
    with Bot.Bot_found -> Empty

  let prune (abs:Abs.t) (constrs:Csp.constrs) =
    let rec aux abs c_list is_sure sures unsures =
      match c_list with
      | [] -> if is_sure then (abs::sures),unsures else sures,(abs::unsures)
      | h::tl ->
	       try
	         let neg = Csp.neg_bexpr h |> filter abs in
	         let s,u = Abs.prune abs neg in
	         let s',u' = List.fold_left (fun (sures,unsures) elm ->
	           aux elm tl is_sure sures unsures)
	           (sures,unsures) s
	         in
	         aux u tl false s' u'
	       with Bot.Bot_found -> aux abs tl is_sure sures unsures
    in aux abs constrs true [] []

  let split abs cstrs = Abs.split abs
(* TODO: add other splits *)
end
