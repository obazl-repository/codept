module Pth = Paths.Pkg

let local file = Pth.local @@ Paths.S.parse_filename file

let organize files =
  let add_name m n  =  Name.Map.add (Unit.extract_name n) (local n) m in
  let m = List.fold_left add_name
      Name.Map.empty (files.Unit.ml @ files.mli) in
  let units = Unit.( split @@ group files ) in
  units, m


let start_env filemap =
  let layered = Envts.Layered.create [] @@ Stdlib.signature in
  let traced = Envts.Trl.extend layered in
  Envts.Tr.start traced filemap

module Param = struct
  let all = false
  let native = false
  let bytecode = false
  let abs_path = false
  let sort = false
  let slash = Filename.dir_sep
  let transparent_aliases = true
  let transparent_extension_nodes = true
  let includes = Name.Map.empty
  let implicits = true
  let no_stdlib = false
end

module S = Solver.Make(Param)

let analyze files =
  let units, filemap = organize files in
  let module Envt = Envts.Tr in
  let core = start_env filemap in
    S.resolve_split_dependencies core units

let normalize set =
  set
  |> Pth.Set.elements
  |> List.map Pth.module_name
  |> List.sort compare


let (%=%) list set =
  normalize set = List.sort compare list

let add_info {Unit.ml; mli} info = match Filename.extension @@ fst info with
  | ".ml" -> { Unit.ml = info :: ml; mli }
  | ".mli" -> { Unit.mli = info :: mli; ml }
  | _ -> raise (Invalid_argument "unknown extension")

let add_file {Unit.ml; mli} info = match Filename.extension @@ info with
  | ".ml" -> { Unit.ml = info :: ml; mli }
  | ".mli" -> { Unit.mli = info :: mli; ml }
  | _ -> raise (Invalid_argument "unknown extension")


let deps_test l =
  let {Unit.ml;mli} = List.fold_left add_info {Unit.ml=[]; mli=[]} l in
  let module M = Paths.S.Map in
  let build exp = List.fold_left (fun m (x,l) ->
      M.add (Paths.S.parse_filename x) l m)
      M.empty exp in
  let exp = M.union' (build ml) (build mli) in
  let files = { Unit.ml = List.map fst ml; mli =  List.map fst mli} in
  let {Unit.ml; mli} = analyze files in
  let (=?) expect files = List.for_all (fun u ->
      let path = u.Unit.path.Pth.file in
      let expected =
          Paths.S.Map.find path expect
      in
      let r = expected %=% u.Unit.dependencies in
      if not r then
        Pp.p "Failure %a: expected:[%a], got:@[[%a]@]\n"
          Pth.pp u.Unit.path
          Pp.(list estring) (List.sort compare expected)
          Pp.(list estring) (normalize u.Unit.dependencies);
      r
    ) files in
  exp =? ml && exp =? mli

let (%) f g x = f (g x)

let cycle_test expected l =
    let files = List.fold_left add_file {Unit.ml=[]; mli=[]} l in
    try ignore @@ analyze files; false with
      S.Cycle (_,units) ->
      let open Solver.Failure in
      let map = analysis units in
      let cmap = categorize map in
      let cmap = normalize map cmap in
      let errs = Map.bindings cmap in
      let name unit = unit.Unit.name in
      let cycles = errs
                  |> List.filter (function (Cycle _, _) -> true | _ -> false)
                  |> List.map snd
                  |> List.map (List.map name % Unit.Set.elements) in
      let expected = List.sort compare expected in
      let cycles = List.sort compare cycles in
      let r = cycles = expected in
      if not r then
        ( Pp.fp Pp.std "Failure: expected %a, got %a\n"
            Pp.(list @@ list string) expected
            Pp.(list @@ list string) cycles;
          r )
      else
        r



let result =
  Sys.chdir "tests";
  List.for_all deps_test [
    ["abstract_module_type.ml", []];
    ["alias_map.ml", ["Aliased__B"; "Aliased__C"] ];
    ["apply.ml", ["F"; "X"]];
    ["basic.ml", ["Ext"; "Ext2"]];
    ["bindings.ml", []];
    ["bug.ml", ["Sys"] ];
    ["case.ml", ["A"; "B";"C";"D";"F"]];
    ["even_more_functor.ml", ["E"; "A"]];
    ["first-class-modules.ml", ["Mark";"B"] ];
    ["first_class_more.ml", [] ];
    ["functor.ml", [] ];
    ["functor_with_include.ml", [] ];
    ["include.ml", ["List"] ];
    ["include_functor.ml", ["A"] ];
    ["letin.ml", ["List"] ];
    ["module_rec.ml", ["Set"] ];
    ["more_functor.ml", ["Ext";"Ext2"] ];
    ["nested_modules.ml", [] ];
    ["no_deps.ml", [] ];
    ["opens.ml", ["A";"B"] ];
    ["pattern_open.ml", ["E1"; "E2"; "E3";"E4"] ];
    ["recmods.ml", ["Ext"]];
    ["record.ml", ["Ext";"E2";"E3"]];
    ["simple.ml", ["G";"E"; "I"; "A"; "W"; "B"; "C"; "Y"; "Ext"]];
    ["solvable.ml", ["Extern"]];
    ["tuple.ml", ["A"; "B"; "C"]];
    ["with.ml", ["Ext"] ]


  ]
  &&
  ( Sys.chdir "network";
  deps_test ["a.ml", ["B"; "Extern"]; "b.ml", []; "c.ml", ["A"] ]
  )
  &&
  ( Sys.chdir "../collision";
    deps_test ["a.ml", ["B"; "Ext"];
               "b.ml", [];
               "c.ml", ["B"];
               "d.ml", ["B"] ]
  )
  &&
  ( Sys.chdir "../pair";
  deps_test ["a.ml", ["B"];  "b.ml", ["Extern"] ]
  )
  && (
    let n = 100 in
    let dep = [ Printf.sprintf "M%d" n ] in
    Sys.chdir "../star";
    ignore @@ Sys.command (Printf.sprintf "ocaml generator.ml %d" 100);
    let rec deps k =
      if k >= n then
        [ Printf.sprintf "m%03d.mli" k, [] ]
      else
        (Printf.sprintf "m%03d.mli" k, dep) :: (deps @@ k+1) in
    deps_test @@ deps 1
  )
    &&
  ( Sys.chdir "../stops";
    deps_test ["a.ml", ["B"; "C"; "D"; "E"; "F"]
              ; "b.ml", ["Z"]
              ; "c.ml", ["Y"]
              ; "d.ml", ["X"]
              ; "e.ml", ["W"]
              ; "f.ml", ["V"]
              ; "v.ml", ["E"]
              ; "w.ml", ["D"]
              ; "x.ml", ["C"]
              ; "y.ml", ["B"]
              ; "z.ml", []
              ]
)
    && (
      Sys.chdir "..";
      cycle_test [["Self_cycle"]] ["self_cycle.ml"]
    )
    &&
    (
      Sys.chdir "ω-cycle";
      cycle_test [["C1";"C2";"C3";"C4";"C5"]] [ "a.ml"
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

let () =
  if result then
    Format.printf "Success.\n"
  else
    Format.printf "Failure.\n"
