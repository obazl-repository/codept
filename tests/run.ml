module Pth = Paths.Pkg

let local = Pth.local

let (%) f g x = f (g x)
let (~:) = List.map Namespaced.make

let classify filename =  match Support.extension filename with
  | "ml" -> { Read.format= Src; kind  = M2l.Structure }
  | "mli" -> { Read.format = Src; kind = M2l.Signature }
  | ext -> raise (Invalid_argument ("unknown extension: "^ext))

module Version = struct
  type t = {major:int; minor:int}
  let v =
    Scanf.sscanf Sys.ocaml_version "%1d.%02d"
    (fun k l -> {major=k;minor=l} )

  let (<=) v v2 =
  v.major < v2.major
  || (v.major = v2.major && v.minor <= v2.minor)

  let v_4_04 = { minor = 4; major = 4}
end


let policy = Standard_policies.quiet

let read policy (info,f,path) =
  Unit.read_file policy info f path

let read_simple policy (info,f) =
  read policy (info, f, Namespaced.of_filename f)

let organize policy files =
  files
  |> Unit.unimap (List.map @@ read policy)
  |> Unit.Groups.Unit.(fst % split % group)

let version = Sys.ocaml_version

let start_env includes fileset =
  Envt.start ~open_approximation:true fileset includes Stdlib.modules


module Branch(Param:Outliner.param) = struct
  module S = Solver.Make(Envt.Core)(Param)
  module D = Solver.Directed(Envt.Core)(Param)

  let organize pkgs files =
    let units: _  Unit.pair = organize policy files in
    let fileset = units.mli
                  |> List.map (fun (u:Unit.s) -> Namespaced.head u.path)
                  |> Name.Set.of_list in
    let env = start_env pkgs fileset in
    env, units

  let analyze_k pkgs files roots =
    let core, units = organize pkgs files in
    let gen = D.generator (read policy)
        (files.ml @ files.mli) in
    S.solve core units,
    Option.fmap (fun roots -> snd @@ D.solve gen core roots) roots

  module CSet =
    Set.Make(struct
      type t = Name.t list
      let compare = compare
    end)

  let analyze_cycle files =
    let core, units = organize [] files in
    let rec solve_and_collect_cycles
        ancestors ?(learn=false) cycles state =
      match ancestors with
      | _ :: grand_father :: _ when S.eq grand_father state ->
        core, cycles
      | _ ->
        match S.resolve_dependencies ~learn state with
        | Ok (e,_) -> e, cycles
        | Error state ->
          let units = state.pending in
          let module F = Solver.Failure in
          let _, cmap = F.analyze (S.alias_resolver state) units in
          let errs = F.Map.bindings cmap in
          let name unit = Solver.(unit.input.path) in
          let more_cycles =
            errs
            |> List.filter (function (F.Cycle _, _) -> true | _ -> false)
            |> List.map snd
            |> List.map (List.map name % Solver.Failure.Set.elements)
            |> (* FIXME*)
            List.map (List.map (fun x -> x.Namespaced.name))
            |> CSet.of_list
          in
          solve_and_collect_cycles (state::ancestors) ~learn
            (CSet.union more_cycles cycles)
          @@ S.approx_and_try_harder state in
    let env, c =
      solve_and_collect_cycles []  ~learn:true CSet.empty
      @@ S.start core units.mli in
    snd @@ solve_and_collect_cycles [] c @@ S.start env units.ml



(*  let ok_only = function
    | Ok l -> l
    | Error (`Ml (_, state) | `Mli state)  ->
      Fault.Log.critical "%a" Solver.Failure.pp_cycle state.S.pending
*)

  let normalize set =
    set
    |> Deps.Forget.to_list
    |> List.sort compare


  let simple_dep_test name list set =
    let r = normalize set = List.sort compare list in
    if not r then
      Pp.p "Failure %a(%s): expected:[%a], got:@[[%a]@]\n"
        Pth.pp name (Sys.getcwd ())
        Pp.(list Paths.P.pp) (List.sort compare list)
        Pp.(list Paths.P.pp) (normalize set);
    r

  let (%) f g x = f (g x)

  let normalize_2 set =
    let l = Deps.Forget.to_list set in
    let is_inner =
      function { Pth.source = Local; _ } -> true | _ -> false in
    let is_lib =
      function { Pth.source = (Pkg _ | Special _ ) ; _ } -> true
             | _ -> false in
    let inner, rest = List.partition is_inner l in
    let lib, unkn = List.partition is_lib rest in
    let norm = List.sort compare % List.map Pth.module_name in
    norm inner, norm lib, norm unkn


  let precise_deps_test name (inner,lib,unkw) set =
    let sort = List.sort compare in
    let inner, lib, unkw = sort inner, sort lib, sort unkw in
    let inner', lib', unkw' = normalize_2 set in
    let test subtitle x y =
      let r = x = y  in
      if not r then
        Pp.p "Failure %a %s: expected:[%a], got:@[[%a]@]\n"
          Pth.pp name subtitle
          Pp.(list estring) x
          Pp.(list estring) y;
      r in
    test "local" inner inner'
    && test "lib" lib lib'
    && test "unknown" unkw unkw'

  let add_info {Unit.ml; mli} (f, info) =
    let k = classify f in
    let x = (k,f,Namespaced.of_filename f, info) in
    match k.kind with
    | M2l.Structure -> { Unit.ml = x :: ml; mli }
    | M2l.Signature -> { Unit.mli = x :: mli; ml }

  let add_file {Unit.ml; mli} file =
    let k = classify file in
    let x = k, file, Namespaced.of_filename file in
    match k.kind with
    | M2l.Structure -> { Unit.ml = x :: ml; mli }
    | M2l.Signature -> { Unit.mli = x :: mli; ml }

  let gen_deps_test libs inner_test roots l =
    let {Unit.ml;mli} =
      List.fold_left add_info {Unit.ml=[]; mli=[]} l in
    let module M = Paths.P.Map in
    let build exp = List.fold_left (fun m (_,f,_n,l) ->
        M.add (Paths.P.local f) l m)
        M.empty exp in
    let exp = M.union (fun _ x _ -> Some x) (build ml) (build mli) in
    let sel (k,f,n, _) = k, f, n in
    let files = Unit.unimap (List.map sel) {Unit.ml;mli} in
    let (u, u' : _ Unit.pair * _ )  =
      analyze_k libs files roots in
    let (=?) expect files = List.for_all (fun u ->
        let path = u.Unit.src in
        let expected =
          M.find path expect
        in
        inner_test u.src expected u.dependencies
      ) files in
    exp =? u.ml && exp =? u.mli && Option.( u' >>| (=?) exp >< true )

  let deps_test (roots,l) =
    gen_deps_test [] simple_dep_test
      (Option.fmap (~:) roots) l

  let deps_test_single l = deps_test (None,l)

  let ocamlfind name =
    let cmd = "ocamlfind query " ^ name in
    let cin = Unix.open_process_in cmd in
    try
      [input_line cin]
    with
      End_of_file -> []

  let cycle_test expected l =
    let files = List.fold_left add_file {Unit.ml=[]; mli=[]} l in
    let cycles = analyze_cycle files in
      let expected = List.map (List.sort compare) expected in
      let cycles = List.map (List.sort compare) (CSet.elements cycles) in
      let r = cycles = expected in
      if not r then
        ( Pp.fp Pp.std "Failure: expected %a, got %a\n"
            Pp.(list @@ list string) expected
            Pp.(list @@ list string) cycles;
          r )
      else
        r
end

module Std = Branch(struct
  let policy = policy
  let epsilon_dependencies = false
  let transparent_aliases = true
  let transparent_extension_nodes = true
  end)

module Eps = Branch(struct
  let policy = policy
  let epsilon_dependencies = true
  let transparent_aliases = true
  let transparent_extension_nodes = true
  end)

let both root x =
  Std.deps_test (Some root, x) && Eps.deps_test (Some root, x)

let l = List.map Paths.P.local
let u = List.map (fun x -> Paths.P.{(local x) with source=Unknown})
let std = List.map
    (fun x -> Paths.P.{(local x) with source=Special "stdlib"})


let result =
  Sys.chdir "tests/cases";
  List.for_all Std.deps_test_single [
    ["abstract_module_type.ml", []];
    ["alias_map.ml", u["Aliased__B"; "Aliased__C"] ];
    ["apply.ml", u["F"; "X"]];
    ["basic.ml", u["Ext"; "Ext2"]];
    ["bindings.ml", []];
    ["bug.ml", std ["Sys"] ];
    ["case.ml", u["A"; "B";"C";"D";"F"]];
    ["even_more_functor.ml", u["E"; "A"]];
    ["first-class-modules.ml", u["Mark";"B"] ];
    ["first_class_more.ml", [] ];
    ["foreign_arg_sig.ml", u["Ext";"Ext2"] ];
    ["functor.ml", [] ];
    ["functor_with_include.ml", [] ];
    [ "hidden.ml", u["Ext"] ];
    ["imperfect_modules.ml", u["Ext"] ];
    ["include.ml", std ["List"] ];
    ["include_functor.ml", u["A"] ];
    ["letin.ml", std ["List"] ];
    ["let_open.ml", [] ];
    ["module_rec.ml", std ["Set"] ];
    ["module_types.ml", u["B"] ];
    ["more_functor.ml", u["Ext";"Ext2"] ];
    ["nested_modules.ml", [] ];
    ["no_deps.ml", [] ];
    ["not_self_cycle.ml", u["E"] ];
    ["nothing.ml", [] ];
    ["unknown_arg.ml", u["Ext"] ];
    ["opens.ml", u["A";"B"] ];
    ["pattern_open.ml", u["A'";"E1"; "E2"; "E3";"E4"] ];
    ["phantom_maze.ml", u["External"; "B"; "C";"D"; "E"; "X"; "Y" ] ];
    ["phantom_maze_2.ml", u["E"; "D"]];
    ["phantom_maze_3.ml", u["B"; "X"] ];
    ["phantom_maze_4.ml", u["Extern"] ];
    ["recmods.ml", u["Ext"]];
    ["record.ml", u["Ext";"E2";"E3"]];
    ["simple.ml", u["G";"E"; "I"; "A"; "W"; "B"; "C"; "Y"; "Ext"]];
    ["solvable.ml", u["Extern"]];
    ["tuple.ml", u["A"; "B"; "C"]];
    ["unknown_arg.ml", u["Ext"] ];
    ["with.ml", u["Ext"] ]
  ]

  && ( Version.( v < v_4_04) ||
       Std.deps_test_single ["pattern_open.ml", u["A'";"E1"; "E2"; "E3";"E4"]] )

  (* Note the inferred dependencies is wrong, but there is not much
     (or far too much ) to do here *)
  && Std.deps_test_single  [ "riddle.ml", u["M5"] ]
  &&
  List.for_all Std.deps_test_single [
    ["broken.ml", u["Ext"; "Ext2"; "Ext3"; "Ext4"; "Ext5" ] ];
    ["broken2.ml", u["A"; "Ext"; "Ext2" ]];
      ["broken3.ml", []];
  ]
  &&( Sys.chdir "../mixed";
      both ["A"] ["a.ml", l["d.mli"];
                 "a.mli", l["b.ml"; "d.mli"];
                 "b.ml", l["c.mli"];
                 "c.mli", l["d.mli"];
                 "d.mli", []
                ]
    )
  && ( Sys.chdir "../aliases";
       both ["User"] [ "amap.ml", l["long__B.ml"];
                   "user.ml", l["amap.ml"; "long__A.ml"];
                   "long__A.ml", [];
                   "long__B.ml", []
                 ]
     )
  && ( Sys.chdir "../aliases2";
       both ["A";"C";"E"] [ "a.ml", l["b.ml"; "d.ml" ];
                   "b.ml", [];
                   "c.ml", [];
                   "d.ml", [];
                   "e.ml", []
                 ]
     )
  && (Sys.chdir "../aliases_and_map";
      both ["n__C"; "n__D"]
        ["n__A.ml", l["m.ml"];
         "n__B.ml", l["m.ml"];
         "n__C.ml", l["m.ml"; "n__A.ml"];
         "n__D.ml", l["m.ml"; "n__B.ml"];
         "m.ml", [];
         "n__A.mli", l["m.mli"];
         "n__B.mli", l["m.mli"];
         "n__C.mli", l["m.mli"];
         "n__D.mli", l["m.mli"];
         "m.mli", [];
        ]
     )
  &&
  ( Sys.chdir "../broken_network";
    both ["A"] [
      "a.ml", (l["broken.ml"; "c.ml"] @ u["B"]);
      "broken.ml", u["B"];
      "c.ml", u["Extern"] ]
  )
  &&
  ( Sys.chdir "../network";
    both ["C"] ["a.ml", l["b.ml"]@ u ["Extern"];
                "b.ml", []; "c.ml", l["a.ml"] ]
  )
  &&
  ( Sys.chdir "../collision";
    both ["A";"C";"D"]
      ["a.ml", l["b.ml"] @ u ["Ext"];
       "b.ml", [];
       "c.ml", l["b.ml"];
       "d.ml", l["b.ml"] ]
  )
  &&
  ( Sys.chdir "../pair";
  both ["A"] ["a.ml", l["b.ml"];  "b.ml", u["Extern"] ]
  )
  &&
  ( Sys.chdir "../namespaced";
    both ["NAME__a"; "NAME__c"] [
      "NAME__a.ml", l["main.ml"; "NAME__b.ml"];
      "NAME__b.ml", l["main.ml"; "NAME__c.ml"];
      "NAME__c.ml", l["main.ml"];
      "main.ml", []
    ]
  )
  &&
  ( Sys.chdir "../module_types";
  both ["B"] ["a.mli", u["E"];  "b.ml", l["a.mli"] ]
  )
  &&
  (
    Sys.chdir "../5624";
    Eps.deps_test
      (Some ["C"],
       [ "a.mli", [];
         "b.mli", l["a.mli"];
         "c.ml", l["a.mli"; "b.mli"]
       ]
      )
  )
  &&
  (
    Sys.chdir "../deep-eps";
    Eps.deps_test
      (Some ["C"] ,
       [
         "a.mli", l["w.mli";"z.mli"; "k.ml"];
         "b.mli", l["a.mli"; "w.mli"; "z.mli"];
         "c.ml", l["a.mli"; "b.mli"; "w.mli"; "z.mli"];
         "k.ml", l["w.mli"; "z.mli"];
         "y.mli", [];
         "w.mli", l["y.mli"];
         "z.mli", l["w.mli"]
       ]
  )
  && (
    let n = 100 in
    let dep = l[ Printf.sprintf "m%d.mli" n ] in
    Sys.chdir "../star";
    ignore @@ Sys.command (Printf.sprintf "ocaml generator.ml %d" 100);
    let rec deps k =
      if k >= n then
        [ Printf.sprintf "m%03d.mli" k, [] ]
      else
        (Printf.sprintf "m%03d.mli" k, dep) :: (deps @@ k+1) in
    both ["M001"] @@ deps 1
  )
    &&
  ( Sys.chdir "../stops";
    both ["A"] ["a.ml", l["b.ml"; "c.ml"; "d.ml"; "e.ml"; "f.ml"]
              ; "b.ml", l["z.ml"]
              ; "c.ml", l["y.ml"]
              ; "d.ml", l["x.ml"]
              ; "e.ml", l["w.ml"]
              ; "f.ml", l["v.ml"]
              ; "v.ml", l["e.ml"]
              ; "w.ml", l["d.ml"]
              ; "x.ml", l["c.ml"]
              ; "y.ml", l["b.ml"]
              ; "z.ml", l[]
              ]
)
    && (
      Sys.chdir "../cases";
      Std.cycle_test [["Self_cycle"]] ["self_cycle.ml"]
    )
    &&
    (
      Sys.chdir "../ω-cycle";
      Std.cycle_test [["C1";"C2";"C3";"C4";"C5"]] [ "a.ml"
                    ; "b.ml"
                    ; "c1.ml"
                    ; "c2.ml"
                    ; "c3.ml"
                    ; "c4.ml"
                    ; "c5.ml"
                    ; "k.ml"
                    ; "l.ml"
                    ; "w.ml"
                                              ]
    )
    && (
      Sys.chdir "../2+2-cycles";
      Std.cycle_test [["A";"B"]; ["C";"D"]] [ "a.ml" ; "b.ml"; "c.ml"; "d.ml"]
    )
    && (
      Sys.chdir "../8-cycles";
      Std.cycle_test [ ["A";"B";"C";"D"]; ["A"; "H"; "G"; "F"; "E"]]
        [ "a.ml" ; "b.ml"; "c.ml"; "d.ml"; "e.ml"; "f.ml"; "g.ml"; "h.ml"]
    )
    && (
      Sys.chdir "../aliased_cycle";
      Std.cycle_test [ ["A"; "B"; "C"]]
        [ "a.ml" ; "b.ml"; "c.ml"; "atlas.ml"]
    )
    &&
    ( Sys.chdir "../../lib";
      Std.gen_deps_test (Std.ocamlfind "compiler-libs") Std.precise_deps_test
        (Some ~:["Solver"; "Standard_policies"])
        [
          "ast_converter.mli", ( ["M2l"], ["Parsetree"], [] );
          "ast_converter.ml", ( ["Loc"; "M2l"; "Name"; "Option"; "Module";
                                 "Paths"],
                                ["List";"Longident"; "Location"; "Lexing";
                                 "Parsetree"], [] );
          "approx_parser.mli", (["M2l"], [],[]);
          "approx_parser.ml", (["Deps"; "Loc"; "Read";"M2l";"Name"],
                               ["Lexer"; "Parser"; "Lexing";"List"],[]);
          "cmi.mli", (["M2l"], [], []);

          "cmi.ml", (["Loc"; "M2l";"Module"; "Option"; "Paths"],
                     ["Cmi_format"; "List"; "Path";"Types"], []);
          "deps.ml", (["Option"; "Paths"; "Pp"; "Sexp"],["List"],[]);
          "summary.mli", (
            ["Module";"Paths";"Sexp"],
            ["Format"],
            [] );
          "summary.ml", (
            ["Module"; "Pp"; "Mresult"; "Name"; "Sexp"],
            ["List"], []);
          "envts.mli", (
            ["Deps"; "Module";"Name"; "Outliner";
             "Paths"], [], []);
          "envts.ml", (
            ["Cmi"; "Deps"; "Summary"; "Outliner"; "M2l"; "Fault";
             "Module"; "Name"; "Namespaced"; "Paths";
             "Standard_faults";"Standard_policies"],
            ["Array"; "Filename"; "List";"Sys"],
            []);
          "outliner.mli", (
            ["Deps"; "Fault"; "Module"; "Namespaced";  "Name";
             "Paths";"M2l"; "Summary"],
            [],[]);
          "outliner.ml", (
            ["Summary"; "Loc"; "M2l"; "Module"; "Name"; "Namespaced";
             "Option"; "Paths"; "Mresult"; "Fault"; "Standard_faults";
             "Deps"]
          ,["List"],[]);
          "m2l.mli", (["Deps";"Loc"; "Module";"Name";"Summary";"Paths";"Sexp" ],
                      ["Format"],[]);
          "m2l.ml", (["Loc"; "Deps"; "Module"; "Mresult"; "Name";
                      "Option";"Summary";"Paths"; "Pp"; "Sexp" ],
                     ["List"],[]);
          "fault.ml", (["Loc"; "Option"; "Name";"Paths"; "Pp"],
                          ["Array"; "Format"],[]);
          "fault.mli", (["Loc"; "Paths"; "Name"],
                          ["Format"],[]);

          "module.mli", ( ["Loc";"Paths";"Name";"Namespaced"; "Sexp"],
                          ["Format"], [] );
          "module.ml", ( ["Loc";"Paths";"Name"; "Namespaced"; "Pp"; "Sexp" ],
                         ["List"], [] );
          "name.mli", ( [], ["Format";"Set";"Map"], [] );
          "name.ml", ( ["Pp"], ["Set";"Map"], [] );
          "namespaced.mli", ( ["Name";"Paths"; "Pp"],
                              ["Set";"Map"], [] );
          "namespaced.ml", ( ["Name"; "Paths"; "Pp"],
                             ["List"; "Set";"Map"], [] );
          "loc.mli", ( ["Sexp"], ["Format"], []);
          "loc.ml", ( ["Pp";"Sexp"], ["List"], []);
          "option.mli", ([],["Lazy"],[]);
          "option.ml", ([],["List"; "Lazy"],[]);
          "paths.mli", (["Name"; "Sexp"], ["Map";"Set";"Format"],[]);
          "paths.ml", (["Name"; "Pp"; "Sexp"; "Support" ],
                       ["Filename";"List";"Map";"Set";"Format"; "String"],[]);
          "pp.mli", ([], ["Format"],[]);
          "pp.ml", ([], ["Format"],[]);
          "read.mli", (["M2l"; "Name"],["Syntaxerr"],[]);
          "read.ml", (["Ast_converter"; "Cmi"; "M2l"],
                      ["Filename"; "Format"; "Lexing"; "Location";
                       "Parsing"; "Pparse"; "String"; "Syntaxerr"],
                      ["Sexp_parse"; "Sexp_lex"]);
          "mresult.mli", ([],[],[]);
          "mresult.ml", ([],["List"],[]);
          "sexp.ml", (["Name"; "Option"; "Pp"],
                      [ "Obj"; "Format";"List";"Map"; "Hashtbl"; "String"], [] );
          "sexp.mli", (["Name"],
                      [ "Format"], [] );
          "solver.mli", (["Deps"; "Fault"; "Loc"; "Unit";"M2l";
                          "Namespaced"; "Read";
                          "Summary"; "Outliner"; "Paths"],
                         ["Format";"Map";"Set"],[]);
          "solver.ml", (
            ["Approx_parser"; "Deps"; "Summary"; "Outliner"; "Loc";
             "M2l"; "Module"; "Mresult"; "Namespaced";
             "Option"; "Pp"; "Paths"; "Read"; "Unit"; "Fault";
             "Standard_faults"],
            ["List"; "Map"; "Set"],[]);
          "standard_faults.ml", (
            ["Fault"; "Module"; "Namespaced"; "Paths"; "Pp"; "Loc" ],
            ["Format"; "Location"; "Syntaxerr"],[]);
          "standard_faults.mli", (
            ["Fault"; "Name"; "Namespaced"; "Module"; "Paths" ],
            ["Syntaxerr"],[]);
          "standard_policies.ml", (["Fault"; "Standard_faults"; "Solver"],[],[]);
          "standard_policies.mli", (["Fault"],[],[]);
          "unit.mli", (["Deps";"Paths"; "M2l"; "Module"; "Namespaced";
                        "Fault"; "Read"],
                       ["Format";"Set"],[]);
          "unit.ml", (
            ["Approx_parser"; "Deps"; "M2l"; "Module"; "Namespaced";
             "Fault"; "Option"; "Paths"; "Pp"; "Read";
             "Standard_faults"],
            [ "List"; "Set"],
            []);
          "support.ml", ([],["String"],[]);
          "support.mli", ([],[],[]);
        ]
      )
    )

let () =
  if result then
    Format.printf "Success.\n"
  else
    Format.printf "Failure.\n"
