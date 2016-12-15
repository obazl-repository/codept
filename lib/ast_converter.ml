
module L = Longident
module B = M2l.Build

module M = Module
module Annot = M2l.Annot
module Arg = M.Arg

let rec from_lid  =
  let open Paths.Expr in
  function
    | L.Lident s -> A s
    | L.Ldot (lid,s) -> S(from_lid lid,s)
    | L.Lapply (f,x) -> F {f = from_lid f; x = from_lid x }

let txt x= x.Location.txt

module H = struct
  let epath x = from_lid @@ txt x
  let npath x = Paths.Expr.concrete @@ epath x

  let access lid =
    let open Paths.Expr in
    match from_lid @@ txt lid with
    | A _ -> Annot.empty
    | S(p,_) -> Annot.access @@ prefix p
    | T | F _ -> assert false

  let do_open lid =
    [M2l.Open (npath lid)]

  let (@%) l l' =
    let open M2l in
    match l,l' with
    | [Minor m] , Minor m' :: q -> Minor( Annot.merge m m') :: q
    | _ -> l @ l'

  let rec gen_mmap (@) f = function
    | [] -> []
    | a :: q -> (f a) @ gen_mmap (@) f q

  let mmap f = gen_mmap (@%) f
  let gmmap f = gen_mmap (@) f

  let (%) f g x = f (g x)

end
open H
let (++) = Annot.(++)

open M2l


module Pattern = struct
  (** {2 Pattern manipulation function} *)

  (** At module level, a pattern can only access modules or
      bind a first class module *)
  type bind = module_expr M2l.bind
  type t = { binds: bind list
           ; annot: Annot.t }

  let empty = { annot = Annot.empty; binds = [] }

  let access p = { empty with annot = access p }
  let value s = { empty with annot = Annot.value s }

  let of_annot annot = { empty with annot }

  let to_annot e = e.annot
  let to_m2l e = Minor (to_annot e)

  let merge e1 e2 = {annot = Annot.( e1.annot ++ e2.annot);
                     binds = e1.binds @ e2.binds }

  let (++) = merge

  let union = List.fold_left merge empty
  let union_map f = List.fold_left (fun p x -> p ++ f x) empty

  let opt f x = Option.( x >>| f >< empty )

  let bind name sign = { empty with binds = [{M2l.name; expr = sign }] }

  let open_ m { annot={values; packed; access}; binds} =
    let values =
      ( if Name.Set.cardinal access > 0 then
          M2l.[Minor { Annot.empty with access}]
        else
          []
      )
      :: values in
    let values = List.map( List.cons (M2l.Open m) ) values in
    let packed = List.map (B.open_me [m]) packed in
    let binds = List.map
        (fun {name;expr} -> {name; expr = B.open_me [m] expr } )
        binds in
    let access = Name.Set.empty in
    { annot={values;access;packed}; binds }

  let bind_fmod p inner =
    let binded =
      List.fold_left ( fun inner b -> M2l.Bind b :: inner )
        [Minor inner] p.binds
      in
      if List.length binded > 1 then
        Annot.( p.annot ++ value [binded] )
      else
        Annot.( p.annot ++ inner )

end

let rec fold2 f acc l1 l2 = match l1, l2 with
  | a :: q, a'::q' -> fold2 f (f acc a a') q q'
  | [], [] -> acc
  | [], _ :: _ | _ :: _, [] -> acc

let minor x =
  if Annot.is_empty x then
    []
  else
    [Minor x]

(** {2 From OCaml ast to m2l } *)
open Parsetree

let rec structure str =
  mmap structure_item str
and structure_item item =
  match item.pstr_desc with
  | Pstr_eval (exp, _attrs) -> minor @@ expr exp
  (* ;; exp [@@_attrs ] *)
  | Pstr_value (_rec_flag, vals)
    (* let P1 = E1 and ... and Pn = EN       (flag = Nonrecursive)
           let rec P1 = E1 and ... and Pn = EN   (flag = Recursive)
    *) ->
    minor @@
    Annot.union_map (Pattern.to_annot % value_binding) vals
  | Pstr_primitive desc
    (*  val x: T
        external x: T = "s1" ... "sn" *)
    -> minor @@ core_type desc.pval_type
  | Pstr_type (_rec_flag, type_declarations)
    (* type t1 = ... and ... and tn = ... *) ->
    minor @@ Annot.union_map type_declaration type_declarations
  | Pstr_typext a_type_extension  (* type t1 += ... *) ->
    minor @@ type_extension a_type_extension
  | Pstr_exception an_extension_constructor
    (* exception C of T
       exception C = M.X *)
    -> minor @@ extension_constructor an_extension_constructor
  | Pstr_module mb (* module X = ME *) ->
    [Bind(module_binding_raw mb)]
  | Pstr_recmodule module_bindings (* module rec X1 = ME1 and ... and Xn = MEn *)
    -> recmodules module_bindings
  | Pstr_modtype a_module_type_declaration (*module type s = .. *) ->
    [ Bind_sig(module_type_declaration a_module_type_declaration) ]
  | Pstr_open open_desc (* open M *) ->
    do_open open_desc.popen_lid
  | Pstr_class class_declarations  (* class c1 = ... and ... and cn = ... *)
    -> minor @@ Annot.union_map class_declaration class_declarations
  | Pstr_class_type class_type_declarations
    (* class type ct1 = ... and ... and ctn = ... *)
    -> minor @@ Annot.union_map class_type_declaration class_type_declarations
  | Pstr_include include_dec (* include M *) ->
    do_include include_dec
  | Pstr_attribute _attribute (* [@@@id] *)
    -> []
  | Pstr_extension ( ext, _attributes) (* [%%id] *) ->
    [extension ext]
and expr exp =
  match exp.pexp_desc with
  | Pexp_ident name (* x, M.x *) ->
    access name
  | Pexp_let (_rec_flag, vbs, exp )
    (* let P1 = E1 and ... and Pn = EN in E       (flag = Nonrecursive)
       let rec P1 = E1 and ... and Pn = EN in E   (flag = Recursive)
    *)
    ->
    value_bindings vbs @@ expr exp
  | Pexp_function cases (* function P1 -> E1 | ... | Pn -> En *) ->
    Annot.union_map case cases
  | Pexp_fun ( _arg_label, expr_opt, pat, expression)
    (* fun P -> E1                          (Simple, None)
       fun ~l:P -> E1                       (Labelled l, None)
       fun ?l:P -> E1                       (Optional l, None)
       fun ?l:(P = E0) -> E1                (Optional l, Some E0)
       Notes:
       - If E0 is provided, only Optional is allowed.
       - "fun P1 P2 .. Pn -> E1" is represented as nested Pexp_fun.
       - "let f P = E" is represented using Pexp_fun.
    *)
    ->
    Annot.opt expr expr_opt
    ++ Pattern.bind_fmod (pattern pat) (expr expression)
  | Pexp_apply (expression, args)
    (* E0 ~l1:E1 ... ~ln:En
       li can be empty (non labeled argument) or start with '?'
       (optional argument).

       Invariant: n > 0
    *)
    ->
    Annot.(expr expression ++ union_map (expr % snd) args)
  | Pexp_match (expression, cases)
  (* match E0 with P1 -> E1 | ... | Pn -> En *)
  | Pexp_try (expression, cases)
    (* try E0 with P1 -> E1 | ... | Pn -> En *)
    ->
    Annot.( expr expression ++  Annot.union_map case cases)
  | Pexp_tuple expressions
    (* (E1, ..., En) Invariant: n >= 2 *)
    ->
    Annot.union_map expr expressions
  | Pexp_construct (constr, expr_opt)
    (* C                None
       C E              Some E
       C (E1, ..., En)  Some (Pexp_tuple[E1;...;En])
    *) ->
    begin match expr_opt with
      | Some e -> Annot.merge (access constr) (expr e)
      | None -> access constr
    end
  | Pexp_variant (_label, eo)
    (* `A             (None)
       `A E           (Some E)
    *)
    -> Annot.opt expr eo
  | Pexp_record (labels, expression_opt)
    (* { l1=P1; ...; ln=Pn }     (None)
       { E0 with l1=P1; ...; ln=Pn }   (Some E0)

       Invariant: n > 0
    *)
    ->
    Annot.( opt expr expression_opt
            ++ union_map (fun (labl,expression) -> H.access labl ++ expr expression )
              labels
          )
  | Pexp_field (expression, field)  (* E.l *) ->
    H.access field ++ expr expression
  | Pexp_setfield (e1, field,e2) (* E1.l <- E2 *) ->
    access field ++ expr e1 ++ expr e2
  | Pexp_array expressions (* [| E1; ...; En |] *) ->
    Annot.union_map expr expressions
  | Pexp_ifthenelse (e1, e2, e3) (* if E1 then E2 else E3 *) ->
    expr e1 ++ expr e2 ++  Annot.opt expr e3
  | Pexp_sequence (e1,e2) (* E1; E2 *) ->
    expr e1 ++ expr e2
  | Pexp_while (e1, e2) (* while E1 do E2 done *) ->
    expr e1 ++ expr e2
  | Pexp_for (pat, e1, e2,_,e3)
    (* for pat = E1 to E2 do E3 done      (flag = Upto)
       for pat = E1 downto E2 do E3 done  (flag = Downto)
    *) ->
    (Pattern.to_annot @@ pattern pat)
    ++ expr e1 ++ expr e2 ++ expr e3
  | Pexp_constraint (e,t) (* (E : T) *) ->
    expr e ++ core_type t
  | Pexp_coerce (e, t_opt, coer)
    (* (E :> T)        (None, T)
       (E : T0 :> T)   (Some T0, T)
    *) ->
    expr e ++ Annot.opt core_type t_opt
    ++ core_type coer

  | Pexp_new name (* new M.c *) ->
    H.access name
  | Pexp_setinstvar (_x, e) (* x <- e *) ->
    expr e
  | Pexp_override labels (* {< x1 = E1; ...; Xn = En >} *) ->
    Annot.union_map (expr % snd) labels
  | Pexp_letmodule (m, me, e) (* let module M = ME in E *) ->
    Annot.value [[ Bind( module_binding (m,me) );
                   Minor( expr e )
                 ]]
  | Pexp_letexception (_c, e) (* let exception C in E *) ->
    expr e
  | Pexp_send (e, _) (*  E # m *)
  | Pexp_assert e (* assert E *)
  | Pexp_newtype (_ ,e) (* fun (type t) -> E *)
  | Pexp_lazy e (* lazy E *) -> expr  e

  | Pexp_poly (e, ct_opt) ->
    expr e ++ Annot.opt core_type ct_opt
  | Pexp_object clstr (* object ... end *) ->
    class_structure clstr
  | Pexp_pack me (* (module ME) *)
    ->  (*Warning.first_class_module (); *)
    (* todo: are all cases caught by the Module.approximation mechanism?  *)
    Annot.pack [module_expr me]
  | Pexp_open (_override_flag,name,e)
    (* M.(E), let open M in E, let! open M in E *)
    -> Annot.value [ do_open name @ [Minor (expr e) ] ]
  | Pexp_extension (name, PStr payload) when txt name = "extension_constructor" ->
    Annot.value [structure payload]
  | Pexp_constant _ | Pexp_unreachable (* . *)
    -> Annot.empty
  | Pexp_extension ext (* [%ext] *) ->
   Annot.value [[extension ext]]
and pattern pat =
  match pat.ppat_desc with
  | Ppat_constant _ (* 1, 'a', "true", 1.0, 1l, 1L, 1n *)
  | Ppat_interval _ (* 'a'..'z'*)
  | Ppat_any

  | Ppat_var _ (* x *) -> Pattern.empty

  | Ppat_extension ext ->
    Pattern.value [[extension ext]]

  | Ppat_exception pat (* exception P *)
  | Ppat_lazy pat (* lazy P *)
  | Ppat_alias (pat,_) (* P as 'a *) -> pattern pat

  | Ppat_array patterns (* [| P1; ...; Pn |] *)
  | Ppat_tuple patterns (* (P1, ..., Pn) *) ->
    Pattern.union_map pattern patterns

  | Ppat_construct (c, p)
    (* C                None
       C P              Some P
       C (P1, ..., Pn)  Some (Ppat_tuple [P1; ...; Pn])
    *) ->
    Pattern.( access c ++ Pattern.opt pattern p )
  | Ppat_variant (_, p) (*`A (None), `A P(Some P)*) ->
    Pattern.opt pattern p
  | Ppat_record (fields, _flag)
    (* { l1=P1; ...; ln=Pn }     (flag = Closed)
       { l1=P1; ...; ln=Pn; _}   (flag = Open)
    *) ->
    Pattern.union_map (fun (lbl,p) -> Pattern.(access lbl ++ pattern p) ) fields
  | Ppat_or (p1,p2) (* P1 | P2 *) ->
    Pattern.( pattern p1 ++ pattern p2 )
  | Ppat_constraint(
      {ppat_desc=Ppat_unpack name; _},
      {ptyp_desc=Ptyp_package s; _ } ) ->
    let name = txt name in
    let mt, others = full_package_type s in
    let bind = {M2l.name; expr = M2l.Constraint(Unpacked, mt) } in
    { others with binds = [bind] }
  (* todo : catch higher up *)
  | Ppat_constraint (pat, ct)  (* (P : T) *) ->
    Pattern.( pattern pat ++ of_annot (core_type ct) )
  | Ppat_type name (* #tconst *) -> Pattern.access name
  | Ppat_unpack m ->
    (* Warning.first_class_module(); todo: test coverage *)
    Pattern.bind (txt m) Unpacked
  (* (module P)
       Note: (module P : S) is represented as
       Ppat_constraint(Ppat_unpack, Ptyp_package)
  *)
  | Ppat_open (m,p) (* M.(P) *) ->
    Pattern.open_ (H.npath m) @@ pattern p

and type_declaration td: M2l.annotation  =
  Annot.union_map (fun (_,t,_) -> core_type t) td.ptype_cstrs
  ++ type_kind td.ptype_kind
  ++ Annot.opt core_type td.ptype_manifest
and type_kind = function
  | Ptype_abstract | Ptype_open -> Annot.empty
  | Ptype_variant constructor_declarations ->
    Annot.union_map constructor_declaration constructor_declarations
  | Ptype_record label_declarations ->
    Annot.union_map label_declaration label_declarations
and constructor_declaration cd =
  Annot.opt core_type cd.pcd_res ++ constructor_args cd.pcd_args
and constructor_args = function
  | Pcstr_tuple cts -> Annot.union_map core_type cts
  | Pcstr_record lds -> Annot.union_map label_declaration lds
and label_declaration ld = core_type ld.pld_type
and type_extension tyext: M2l.annotation =
  access tyext.ptyext_path
  ++ Annot.union_map  extension_constructor tyext.ptyext_constructors
and core_type ct : M2l.annotation = match ct.ptyp_desc with
  | Ptyp_extension ext (* [%id] *) ->
    Annot.value [[ extension ext ]]
  | Ptyp_any  (*  _ *)
  | Ptyp_var _ (* 'a *) -> Annot.empty
  | Ptyp_arrow (_, t1, t2) (* [~? ]T1->T2 *) ->
    core_type t1 ++ core_type t2
  | Ptyp_tuple cts (* T1 * ... * Tn *) ->
    Annot.union_map core_type cts
  | Ptyp_class (name,cts)
  | Ptyp_constr (name,cts) (*[|T|(T1n ..., Tn)] tconstr *) ->
    access name
    ++ Annot.union_map core_type cts
  | Ptyp_object (lbls, _ ) (* < l1:T1; ...; ln:Tn[; ..] > *) ->
    Annot.union_map  (fun  (_,_,t) -> core_type t) lbls
  | Ptyp_poly (_, ct)
  | Ptyp_alias (ct,_) (* T as 'a *) -> core_type ct

  | Ptyp_variant (row_fields,_,_labels) ->
    Annot.union_map row_field row_fields
  | Ptyp_package s (* (module S) *) ->
    package_type s

and row_field = function
  | Rtag (_,_,_,cts) -> Annot.union_map core_type cts
  | Rinherit ct -> core_type ct
and package_type (s,constraints) =
  Annot.merge
    (access s)
    (Annot.union_map (core_type % snd) constraints)
and full_package_type (s,constraints) =
  Ident (epath s),
  Pattern.of_annot @@ Annot.union_map (core_type % snd) constraints
and case cs =
  (Annot.opt expr cs.pc_guard)
  ++ (Pattern.bind_fmod (pattern cs.pc_lhs) @@ expr cs.pc_rhs)
and do_include incl =
  [ Include (module_expr incl.pincl_mod) ]
and extension_constructor extc: M2l.annotation = match extc.pext_kind with
  | Pext_decl (args, cto) ->
    constructor_args args
    ++ Annot.opt core_type cto
  | Pext_rebind name -> access name
and class_type ct = match ct.pcty_desc with
  | Pcty_constr (name, cts ) (* c ['a1, ..., 'an] c *) ->
    Annot.merge (access name) (Annot.union_map core_type cts)
  | Pcty_signature cs (* object ... end *) -> class_signature cs
  | Pcty_arrow (_arg_label, ct, clt) (* ^T -> CT *) ->
    Annot.( class_type clt ++ core_type ct)
  | Pcty_extension ext (* [%ext] *) ->
    Annot.value [[ extension ext ]]
and class_signature cs = Annot.union_map class_type_field cs.pcsig_fields
and class_type_field ctf = match ctf.pctf_desc with
  | Pctf_inherit ct -> class_type ct
  | Pctf_val ( _, _, _, ct) (*val x : T *)
  | Pctf_method (_ ,_,_,ct) (* method x: T *)
    -> core_type ct
  | Pctf_constraint  (t1, t2) (* constraint T1 = T2 *) ->
    Annot.( core_type t2 ++ core_type t1 )
  | Pctf_attribute _ -> Annot.empty
  | Pctf_extension ext ->
    Annot.value [[ extension ext ]]
and class_structure ct =
  Annot.union_map class_field ct.pcstr_fields
and class_field  field = match field.pcf_desc with
  | Pcf_inherit (_override_flag, ce, _) (* inherit CE *) ->
    class_expr ce
  | Pcf_method (_, _, cfk)
  | Pcf_val (_,_, cfk) (* val x = E *)->
    class_field_kind cfk
  | Pcf_constraint (_ , ct) (* constraint T1 = T2 *) ->
    core_type ct
  | Pcf_initializer e (* initializer E *) -> expr e
  | Pcf_attribute _ -> Annot.empty
  | Pcf_extension ext -> Annot.value [[extension ext]]
and class_expr ce = match ce.pcl_desc with
  | Pcl_constr (name, cts)  (* ['a1, ..., 'an] c *) ->
    access name ++ Annot.union_map core_type cts
  | Pcl_structure cs (* object ... end *) -> class_structure cs
  | Pcl_fun (_arg_label, eo, pat, ce)
    (* fun P -> CE                          (Simple, None)
       fun ~l:P -> CE                       (Labelled l, None)
       fun ?l:P -> CE                       (Optional l, None)
       fun ?l:(P = E0) -> CE                (Optional l, Some E0)
    *)
    -> Annot.merge (Annot.opt expr eo)
         (Pattern.bind_fmod (pattern pat) (class_expr ce) )
  | Pcl_apply (ce, les )
    (* CE ~l1:E1 ... ~ln:En
       li can be empty (non labeled argument) or start with '?'
       (optional argument).

       Invariant: n > 0
    *) ->
    Annot.union_map (expr % snd) les ++ class_expr ce
  | Pcl_let (_, vbs, ce ) (* let P1 = E1 and ... and Pn = EN in CE *)
    ->
    value_bindings vbs (class_expr ce)
  | Pcl_constraint (ce, ct) ->
    class_type ct ++ class_expr ce
  | Pcl_extension ext ->
    Annot.value [[ extension ext ]]
and class_field_kind = function
  | Cfk_virtual ct -> core_type ct
  | Cfk_concrete (_, e) -> expr e
and class_declaration cd: M2l.annotation = class_expr cd.pci_expr
and class_type_declaration ctd: M2l.annotation = class_type ctd.pci_expr
and module_expr mexpr : M2l.module_expr =
  match mexpr.pmod_desc with
  | Pmod_ident name (* A *) ->
    Ident (npath name)
  | Pmod_structure str (* struct ... end *) ->
    Str (structure  str)
  | Pmod_functor (name, sign, mex) ->
    let name = txt name in
    let arg = Option.( sign >>| module_type >>| fun s -> {Arg.name;signature=s} ) in
    Fun { arg; body = module_expr mex }
  | Pmod_apply (f,x)  (* ME1(ME2) *) ->
    Apply {f = module_expr f; x = module_expr x }
  | Pmod_constraint (me,mt) ->
    Constraint(module_expr me, module_type mt)
  | Pmod_unpack { pexp_desc = Pexp_constraint
                      (inner, {ptyp_desc = Ptyp_package s; _}); _ }
    (* (val E : S ) *) ->
    Constraint( Val (expr inner), fst @@ full_package_type s)
  | Pmod_unpack e  (* (val E) *) ->
    Val(expr e)
  | Pmod_extension ext ->
    Extension_node(extension_core ext)
(* [%id] *)
and value_binding vb : Pattern.t =
  let p, e = matched_patt_expr vb.pvb_pat vb.pvb_expr in
  Pattern.( p ++ of_annot e )
and value_bindings vbs expr =
  let p = Pattern.union_map value_binding vbs in
  if List.length p.binds > 0 then
    let v = List.fold_left ( fun inner b -> Bind b :: inner )
        (minor expr) p.binds in
    Annot.value [v]
  else
    Pattern.to_annot p ++ expr

and module_binding_raw mb =
  module_binding (mb.pmb_name, mb.pmb_expr)
and module_binding (pmb_name, pmb_expr) =
  { name = txt pmb_name; expr = module_expr pmb_expr }
and module_type (mt:Parsetree.module_type) =
  match mt.pmty_desc with
  | Pmty_signature s (* sig ... end *) -> Sig (signature s)
  | Pmty_functor (name, arg, res) (* functor(X : MT1) -> MT2 *) ->
    let arg = let open Option in
      arg >>| module_type >>| fun s -> { Arg.name = txt name; signature = s} in
    Fun { arg; body = module_type res }
  | Pmty_with (mt, wlist) (* MT with ... *) ->
    let deletions = Name.Set.of_list @@  gmmap dels wlist in
    With { body = module_type mt; deletions }
  | Pmty_typeof me (* module type of ME *) ->
    Of (module_expr me)
  | Pmty_extension ext (* [%id] *) ->
    Extension_node (extension_core ext)
  | Pmty_alias lid -> Alias (npath lid)
  | Pmty_ident lid (* S *) -> Ident (epath lid)
and module_declaration mdec =
  let s = module_type mdec.pmd_type in
  { name = txt mdec.pmd_name; expr = Constraint( Abstract, s) }
and module_type_declaration mdec =
  let open Option in
  let name = txt mdec.pmtd_name in
  let s = ( (mdec.pmtd_type >>| module_type) >< Abstract ) in
  {name; expr = s }
and signature sign =
  mmap signature_item sign
and signature_item item =  match item.psig_desc with
  | Psig_value vd (* val x: T *) ->
    minor (core_type vd.pval_type)
  | Psig_type (_rec_flag, tds) (* type t1 = ... and ... and tn = ... *) ->
    minor @@ Annot.union_map type_declaration tds
  | Psig_typext te (* type t1 += ... *) ->
    minor @@ type_extension te
  | Psig_exception ec (* exception C of T *) ->
    minor @@ extension_constructor ec
  | Psig_module md (* module X : MT *) ->
    [Bind (module_declaration md)]
  | Psig_recmodule mds (* module rec X1 : MT1 and ... and Xn : MTn *) ->
    [Bind_rec (List.map module_declaration mds)]
  (* Warning.confused "Psig_recmodule"; (* todo coverage*) *)
  | Psig_modtype mtd (* module type S = MT *) ->
    [Bind_sig(module_type_declaration mtd)]
  | Psig_open od (* open X *) ->
    do_open od.popen_lid
  | Psig_include id (* include MT *) ->
    [ SigInclude (module_type id.pincl_mod) ]
  | Psig_class cds (* class c1 : ... and ... and cn : ... *) ->
    minor @@ Annot.union_map class_description cds
  | Psig_class_type ctds ->
    minor @@ Annot.union_map class_type_declaration ctds
  | Psig_attribute _ -> []
  | Psig_extension (ext,_) -> [extension ext]
and class_description x =  class_type_declaration x
and recmodules mbs =
  [Bind_rec (List.map module_binding_raw mbs)]
and dels  =
  function
  | Pwith_typesubst _ (* with type t := ... *)
  | Pwith_type _(* with type X.t = ... *) -> []
  | Pwith_module _ (* with module X.Y = Z *) -> []
  | Pwith_modsubst (name, _) ->
    let name = txt name in
    [name]
and extension n = Extension_node (extension_core n)
and extension_core (name,payload) =
  let open M2l in
  let name = txt name in
  match payload with
  | PSig s ->  {extension = Module (signature s); name }
  | PStr s ->  {extension = Module (structure s); name }
  | PTyp c ->  {extension = Val (core_type c); name }
  | PPat (p, eo) ->
    {extension = Val
         ( Pattern.to_annot (pattern p) ++ Annot.opt expr eo)
    ; name }
and matched_patt_expr x y =
  (* matched_patt_expr is used to catch some case of packed module
      where the module signature is provided not on the pattern side
      but on the expression side
  *)
  match x.ppat_desc, y.pexp_desc with
  | Ppat_constraint _ , Pexp_constraint _ -> pattern x, expr y
  | _, Pexp_constraint (_,t) ->
    pattern { x with ppat_desc = Ppat_constraint(x,t)}, expr y
  | Ppat_construct (_,po), Pexp_construct(_,eo)|
    Ppat_variant (_,po), Pexp_variant(_,eo)
    ->
    Option.( (po >>= fun p -> eo >>| fun e -> matched_patt_expr p e) ><
             (Pattern.opt pattern po, Annot.opt expr eo)
           )
  | Ppat_tuple pt, Pexp_tuple et
  | Ppat_array pt, Pexp_array et  (* todo use homogeneity *)
    ->
    fold2
      (fun (p,e) x y -> let p',e' = matched_patt_expr x y in
        Pattern.( p ++ p'), e ++ e' ) (Pattern.empty, Annot.empty) pt et
  | Ppat_record (pr,_) , Pexp_record (er,eo) ->
    (* First, gather together pattern and expression with the same label *)
    let m = Paths.Simple.Map.empty in
    let alt a x = match x with None -> Some a | _ -> x in
    let add_p p' (p,e) = alt p' p, e in
    let add_e e' (p,e) = p, alt e' e in
    let folder add m (key,x) =
      let key = H.npath key in
      let v = try add x @@ Paths.Simple.Map.find key m with
        | Not_found -> None, None in
      Paths.Simple.Map.add key v m in
    let m = List.fold_left (folder add_p) m pr in
    let m = List.fold_left (folder add_e) m er in
    (* Then use matched pattern expression analyse, when both pattern
       and expression are available *)
    Paths.Simple.Map.fold (fun _ elt (acc_p,acc_e) -> match elt with
        | Some p, Some e ->
          let p, e = matched_patt_expr p e in
          Pattern.( acc_p ++ p ), acc_e ++ e
        | None, None -> acc_p, acc_e
        | Some p, None -> Pattern.( acc_p ++ pattern p), acc_e
        | None, Some e -> acc_p , acc_e ++ expr e
      ) m (Pattern.empty, Annot.opt expr eo)
  | _, _ -> pattern x, expr y
