module M = Module
module Edge = Deps.Edge
module P = Paths.Pkg
module Out = Outliner
module Y = Summary

let debug fmt = Format.ifprintf Pp.err ("Debug:" ^^ fmt ^^"@.")

type answer = Out.answer =
  | M of Module.m
  | Namespace of Module.namespace_content

type context =
  | Signature of M.signature
  | In_namespace of M.dict

module Query = struct

  type 'a t = 'a Outliner.query_result option
  let return main = Some { Outliner.main; deps = Deps.empty; msgs = [] }
  let deps deps = Some {Outliner.main=(); deps; msgs=[]}

  let (>>|) x f = { x with Outliner.main = f x.Outliner.main }
  let (>>?) (x: _ t) f = let open Option in
    x >>= fun x -> f x.Out.main >>| fun q ->
    { q with Out.msgs= x.msgs @ q.Out.msgs; deps=Deps.merge q.Out.deps x.deps }

  let (>>) x y = x >>? fun () -> y

  let (<!>) x msgs =
    Option.fmap (fun x -> { x with Out.msgs = msgs @ x.Out.msgs }) x

end
open Query

type module_provider = Name.t -> Module.t Query.t
let last l = List.hd @@ List.rev l

let to_context s = Signature (Exact s)

let ambiguity name breakpoint =
  let f = Standard_faults.ambiguous in
  { f  with
    Fault.log = (fun lvl l -> f.log lvl l name breakpoint)
  }

let nosubmodule current level name =
  let fault = Standard_faults.nonexisting_submodule in
  {  fault with
     Fault.log = (fun lvl l ->
         fault.log lvl l (List.rev current) level name
       )
  }

let unknown mlvl path =
  let fault = Standard_faults.unknown_approximated in
  {  fault with
     Fault.log = (fun lvl -> fault.log lvl mlvl path)
  }


module Core = struct

  type t = {
    top: M.Dict.t;
    current: context;
    providers: module_provider list;
  }

  let empty = {
    top = Name.Map.empty;
    current = Signature(Exact(M.Def.empty));
    providers = []
  }

  let eq x y= x.top = y.top
  let start s =
    { top = s.M.modules; current = to_context s;
      providers = []
    }

  let pp_context ppf = function
    | In_namespace modules ->
      Pp.fp ppf "namespace [%a]@." Module.pp_mdict modules
    | Signature sg -> Pp.fp ppf "[%a]@." Module.pp_signature sg

  let pp ppf x = Pp.fp ppf "@[top=%a@ context=%a@]"
      M.pp_mdict x.top pp_context x.current

  module D = struct
    let path_record ~path ?aliases ~edge pkg  =
      deps (Deps.make ~path ?aliases ~edge pkg )

    let phantom_record ?aliases name =
      path_record ~path:[name] ?aliases ~edge:Edge.Normal
        { P.source = Unknown; file = [name] }

    let record edge ?aliases root (m:Module.m) =
      match m.origin with
      | M.Origin.Unit p -> path_record ~path:p.path ?aliases ~edge p.source
      | Phantom (phantom_root, b) when root && not phantom_root ->
        phantom_record ?aliases m.name <!> [ambiguity m.name b]
      | _ -> return ()
  end

  let request lvl name env =
    let rec request name  = function
      | [] -> None
      | f :: q ->
        match f name with
        | Some _ as q -> q
        | None -> request name q in
    if lvl = M.Module then
      request name env.providers
    else None


  let proj lvl def = match lvl with
    | M.Module -> def.M.modules
    | M.Module_type -> def.module_types


  let adjust_level level = function
    | [] -> level
    | _ :: _ -> M.Module

  let restrict env context = { env with current = context }
  let top env =
    { env with current = Signature (Exact (M.Def.modules env.top) ) }

  let find_opt name m =
    match Name.Map.find name m with
    | exception Not_found -> None
    | x -> return x

  let rec find_name phantom level name current =
    match current with
    | Signature Module.Blank ->
      (* we are already in error mode here, no need to emit yet another warning *)
      return (M.md @@ M.mockup name)
    | In_namespace modules ->
      if level = M.Module_type then None
      else find_opt name modules
    | Signature Exact def -> find_opt name @@ proj level def
    | Signature Divergence d ->
      (* If we have a divergent signature, we first look
         at the signature after the divergence: *)
      match find_opt name @@ proj level d.after with
      | Some _ as x -> x
      | None ->
        let open Query in
        let (|||) = Option.(|||) in

        (* We then try to find the searched name in the signature
           before the divergence *)
        begin find_name true level name (Signature d.before) >>? fun q ->
          let m = Module.spirit_away d.point q in
          if phantom then return m else return m <!> [ambiguity name d.point]
          (* If we found the expected name before the divergence,
              we add a new message to the message stack, and return
              the found module, after marking it as a phantom module. *)
        end
        (* If we did not find anything and were looking for a module type,
           we return a mockup module type *)
        ||| lazy (if level = Module_type then
                    return (M.md @@ M.mockup name) <!> [unknown Module_type name]
                  else None)

  let find_name = find_name false

  type ctx =
    | Any (** look for aliases too *)
    | Concrete (** we are looking for a concrete unit *)
    | Submodule

  let is_top = function Any | Concrete -> true | Submodule -> false

  type option =
    { level:M.level; edge:Edge.t; approx_submodule:bool }

  (** Should we return a mockup module and a warning? *)
  let approx_submodule o ctx lvl =
    o.approx_submodule && (ctx = Submodule || lvl=M.Module_type)

  let rec find option aliases ctx current env path =
    debug "looking for %a" Paths.S.pp path;
    debug "in %a, sub-approx: %B" pp_context env.current option.approx_submodule;
    match path with
    | [] -> None (* should not happen *)
    | a :: q ->
      let lvl = adjust_level option.level q in
      let r = match find_name lvl a env.current with
        | None when approx_submodule option ctx lvl ->
          debug "submodule approximate %s" (last path);
          return (M.md @@ M.mockup @@ last path) <!> [nosubmodule current lvl a]
        | None -> request lvl a env
        | Some _ as x -> x in
      r >>? find_elt option aliases ctx env (a::current) q
  and find_elt option aliases ctx env current q = function
    | Alias {path; phantom; name; weak = false } ->
      debug "alias to %a" Namespaced.pp path;
      let aliases = Paths.S.Set.add (List.rev current) aliases in
      let m = match phantom with
        | Some b when is_top ctx -> D.phantom_record name <!> [ambiguity name b]
        | None | Some _ -> return () in
      (* aliases link only to compilation units *)
      m >> find option aliases Any [] (top env) (Namespaced.flatten path @ q)
    | Alias { weak = true; _ } when ctx = Concrete -> None
    | Alias {path; weak = true; _ } ->
      find option aliases Concrete [] (top env) (Namespaced.flatten path @ q)
    | M.M m ->
      debug "found module %s" m.name;
      D.record option.edge ~aliases (is_top ctx) m >>
      if q = [] then return (M m)
      else
        find option aliases Submodule current (restrict env @@ Signature m.signature) q
    | Namespace {name;modules} ->
      (* let faults = record edge root env name in*)
      if q = [] then return (Namespace {name;modules})
      else find option aliases ctx current (restrict env @@ In_namespace modules) q

  let find sub ?edge level path envt =
    let edge = Option.default Edge.Normal edge in
    let option = {approx_submodule=sub; edge; level } in
    match find option Paths.S.Set.empty Any [] envt path with
    | None -> raise Not_found
    | Some x -> x

  let find_implicit = find false
  let find = find true

  let to_sign = function
    | Signature s -> s
    | In_namespace modules -> M.Exact { M.Def.empty with modules }

  let extend env def =
    restrict env @@ Signature (Y.extend (to_sign env.current) def)

  let add_unit env ?(namespace=[]) x =
    let m: Module.t = M.with_namespace namespace x in
    let t = Module.Dict.( union env.top (of_list [m]) ) in
    debug "@[<hov 2>adding %s to@ @[[%a]@] yielding@ @[[%a]@]@]"
      (M.name m) M.pp_mdict env.top M.pp_mdict t;
    top { env with top = t }

  let add_namespace env (nms:Namespaced.t) =
    let add x = top M.Dict.{ env with top = union env.top @@ of_list [x] } in
    debug "@[<v 2>Adding %a@; to %a@]@." Namespaced.pp nms pp_context
      env.current;
    if nms.namespace = [] then
      add (M.Alias { name= nms.name; path=nms; phantom = None; weak = true })
    else
      add (Module.namespace nms)

  let rec resolve_alias_md path def =
    match path with
    | [] -> None
    | a :: q ->
      match Name.Map.find a def with
      | M.Alias {path; _ } ->
        debug "resolved to %a" Namespaced.pp path;
        Some path
      | M m -> resolve_alias_sign q m.signature
      | Namespace n -> resolve_alias_md q n.modules
      | exception Not_found -> None
  and resolve_alias_sign path = function
    | Blank -> None
    | Exact s -> resolve_alias_md path s.modules
    | Divergence d ->
      match resolve_alias_md path d.after.modules with
      | Some _ as r -> r
      | None ->
        (* FIXME: Should we warn here? *)
        resolve_alias_sign path d.before

  let resolve_alias path env =
    debug "resolving %a" Paths.S.pp path;
    match env.current with
    | In_namespace md -> resolve_alias_md path md
    | Signature sg -> resolve_alias_sign path sg

  let is_exterior path envt =
    match path with
    | [] -> false (* should not happen *)
    | a :: _ ->
      match find_name Module a envt.current with
      | None -> true
      | Some m ->
        match m.main with
        | Namespace _ -> true
        | M { origin = Unit _; _ } -> true
        | M.Alias a -> a.weak
        | _ -> false

  let expand_path path envt =
    match path with
    | [] -> []
    | a :: q ->
      match find_name Module a envt.current with
      | None -> path
      | Some m ->
        match m.main with
        | Namespace _ -> path
        | M { origin = Unit {path=p; _ } ; _ } -> p @ q
        | M.Alias {path;_} -> Namespaced.flatten path @ q
        | _ -> path


  let pp ppf x = pp ppf x
end

let approx name =
  Module.mockup name ~path:{Paths.P.source=Unknown; file=[name]}

let open_world () =
  let mem = ref Name.Set.empty in
  let warn request =
    if Name.Set.mem request !mem then [] else
      (mem := Name.Set.add request !mem; [unknown Module request] ) in
  fun request ->
    debug "open world: requesting %s" request;
    return (M.md @@ approx request) <!> (warn request)

module Libraries = struct

  type source = {
    origin: Paths.Simple.t;
    mutable resolved: Core.t;
    cmis: P.t Name.map
  }


  let read_dir dir =
    let files = Sys.readdir dir in
    let origin = Paths.S.parse_filename dir in
    let cmis_map =
      Array.fold_left (fun m x ->
          if Filename.check_suffix x ".cmi" then
            let p =
              {P.source = P.Pkg origin; file = Paths.S.parse_filename x} in
            Name.Map.add (P.module_name p) p m
          else m
        )
        Name.Map.empty files in
    { origin; resolved= Core.start M.Def.empty; cmis= cmis_map }

  let create includes =  List.map read_dir includes

  module I = Outliner.Make(Core)(struct
      let policy = Standard_policies.quiet
      let transparent_aliases = false
      (* we are not recording anything *)
      let transparent_extension_nodes = false
      (* extension nodes should not appear in cmi *)
      let epsilon_dependencies = false
      (* do no try epsilon dependencies yet *)
    end)


  let rec track source stack = match stack with
    | [] -> ()
    | (name, path, code) :: q ->
      match Outliner.With_deps.value (I.m2l path source.resolved code) with
      | Error code ->
        begin match M2l.Block.m2l code with
          | None -> assert false
          | Some { data = _y, bl_path ; _ } ->
            let name' = List.hd bl_path in
            let path' = Name.Map.find name' source.cmis in
            let code' = Cmi.m2l @@ P.filename path' in
            track source ( (name', path', code') :: (name, path, code) :: q )
        end
      | Ok (_, sg) ->
        let md = M.create
            ~origin:(M.Origin.Unit {source=path;path=[name]}) name sg in
        source.resolved <- Core.add_unit source.resolved (M.M md);
        track source q

  let rec pkg_find name source =
    match Core.find_name M.Module name source.resolved.current with
    | Some {main =
              M.M { origin = Unit {source={ source = Unknown; _ }; _ }; _ }; _} ->
      raise Not_found
    | None ->
      let path = Name.Map.find name source.cmis in
      track source
        [name, path, Cmi.m2l @@ P.filename path ];
      pkg_find name source
    | Some m -> m.Out.main

  let rec pkgs_find name = function
    | [] -> raise Not_found
    | source :: q ->
      try
        let m = pkg_find name source in
        m
      with Not_found ->
        pkgs_find name q

  let provider libs =
    let pkgs = create libs in
    fun name ->
      debug "library layer: requesting %s" name;
      match pkgs_find name pkgs with
      | exception Not_found -> None
      | q -> return q
end
let libs = Libraries.provider

module Implicit_namespace = struct

  let provider (namespace,modules) =
    let open Query in
    let wrap = function
      | M m -> M.M m
      | Namespace {name;modules} ->
        M.Namespace {name; modules} in
    let env = Core.start (M.Def.modules modules) in
    fun name ->
      try
        Some(Core.find_implicit M.Module [name] env >>| wrap)
      with Not_found ->
      try
        Some(Core.find_implicit M.Module (namespace @ [name]) env >>| wrap)
      with Not_found -> None

end
let implicit_namespace = Implicit_namespace.provider


let start ?(open_approximation=true)
    ~libs ~namespace ~implicits predefs  =
  let empty = Core.start M.Def.empty in
  let files_in_namespace =
    List.fold_left Core.add_namespace empty namespace in
  let env =
    (* predefs should not override existing files *)
    Core.start @@ M.Def.modules
    @@ M.Dict.weak_union files_in_namespace.top predefs in
  let implicits = List.map implicit_namespace implicits in
  let libs = if not (libs = []) then [Libraries.provider libs] else [] in
  let open_approx = if open_approximation  then [open_world ()] else [] in
  { env with providers= libs @ implicits @ open_approx }
