(*
This module originated as a copy of interpreter/binary/encode.ml in the
reference implementation.

The changes are:
 * Support for writing out a source map for the Code parts
 * Support for additional custom sections

The code is otherwise as untouched as possible, so that we can relatively
easily apply diffs froim the original code (possibly manually).
*)

open CustomModule

(* Version *)

let version = 1l


(* Errors *)

module Code = Wasm.Error.Make ()


(* Encoding stream *)

type stream =
{
  buf : Buffer.t;
  patches : (int * char) list ref
}

let stream () = {buf = Buffer.create 8192; patches = ref []}
let pos s = Buffer.length s.buf
let put s b = Buffer.add_char s.buf b
let put_string s bs = Buffer.add_string s.buf bs
let patch s pos b = s.patches := (pos, b) :: !(s.patches)

let to_string s =
  let bs = Buffer.to_bytes s.buf in
  List.iter (fun (pos, b) -> Bytes.set bs pos b) !(s.patches);
  Bytes.to_string bs


(* Encoding *)

let encode (em : extended_module) =
  let s = stream () in

  (* source map *)
  let map = Buffer.create 0 in
  let sources = ref [] in
  let sourcesContent = ref [] in
  let segs = ref 0 in
  let prev_if = ref 0 in
  let prev_ol = ref 0 in
  let prev_oc = ref 0 in
  let prev_il = ref 0 in
  let prev_ic = ref 0 in

  let rec add_source x lst = match lst with
    | [] ->
      sources := !sources @ [ x ];
      sourcesContent := !sourcesContent @ [ "" ];
      0
    | h :: t -> if x = h then 0 else 1 + (add_source x t)
  in

  sources := !sources @ [ "prelude" ];
  sourcesContent := !sourcesContent @ [ Prelude.prelude ];

  let add_to_map file il ic ol oc =
    let il = il - 1 in
    let if_ = add_source file !sources in
    if ol <> !prev_ol then Buffer.add_char map ';';
    Vlq.Base64.encode map (oc - !prev_oc);             (* output column *)
    Vlq.Base64.encode map (if_ - !prev_if);            (* sources index *)
    Vlq.Base64.encode map (il - !prev_il);             (* input row *)
    Vlq.Base64.encode map (ic - !prev_ic);             (* input column *)
    Buffer.add_char map ',';

    prev_if := if_; prev_ol := ol; prev_oc := oc; prev_il := il; prev_ic := ic; segs := !segs + 1
  in

  let module E = struct
    (* Generic values *)

    let u8 i = put s (Char.chr (i land 0xff))
    let u16 i = u8 (i land 0xff); u8 (i lsr 8)
    let u32 i =
      Int32.(u16 (to_int (logand i 0xffffl));
             u16 (to_int (shift_right i 16)))
    let u64 i =
      Int64.(u32 (to_int32 (logand i 0xffffffffL));
             u32 (to_int32 (shift_right i 32)))

    let rec vu64 i =
      let b = Int64.(to_int (logand i 0x7fL)) in
      if 0L <= i && i < 128L then u8 b
      else (u8 (b lor 0x80); vu64 (Int64.shift_right_logical i 7))

    let rec vs64 i =
      let b = Int64.(to_int (logand i 0x7fL)) in
      if -64L <= i && i < 64L then u8 b
      else (u8 (b lor 0x80); vs64 (Int64.shift_right i 7))

    let vu1 i = vu64 Int64.(logand (of_int i) 1L)
    let vu32 i = vu64 Int64.(logand (of_int32 i) 0xffffffffL)
    let vs7 i = vs64 (Int64.of_int i)
    let vs32 i = vs64 (Int64.of_int32 i)
    let vs33 i = vs64 (Wasm.I64_convert.extend_i32_s i)
    let f32 x = u32 (Wasm.F32.to_bits x)
    let f64 x = u64 (Wasm.F64.to_bits x)

    let len i =
      if Int32.to_int (Int32.of_int i) <> i then
        Code.error Wasm.Source.no_region
          "cannot encode length with more than 32 bit";
      vu32 (Int32.of_int i)

    let bool b = vu1 (if b then 1 else 0)
    let string bs = len (String.length bs); put_string s bs
    let name n = string (Wasm.Utf8.encode n)
    let list f xs = List.iter f xs
    let opt f xo = Lib.Option.app f xo
    let vec f xs = len (List.length xs); list f xs
    let veci f xs = len (List.length xs); List.iteri f xs

    let gap32 () = let p = pos s in u32 0l; u8 0; p
    let patch_gap32 p n =
      assert (n <= 0x0fff_ffff); (* Strings cannot excess 2G anyway *)
      let lsb i = Char.chr (i land 0xff) in
      patch s p (lsb (n lor 0x80));
      patch s (p + 1) (lsb ((n lsr 7) lor 0x80));
      patch s (p + 2) (lsb ((n lsr 14) lor 0x80));
      patch s (p + 3) (lsb ((n lsr 21) lor 0x80));
      patch s (p + 4) (lsb (n lsr 28))

    (* Types *)

    open Wasm.Types

    let value_type = function
      | I32Type -> vs7 (-0x01)
      | I64Type -> vs7 (-0x02)
      | F32Type -> vs7 (-0x03)
      | F64Type -> vs7 (-0x04)

    let elem_type = function
      | FuncRefType -> vs7 (-0x10)

    let stack_type = vec value_type
    let func_type = function
      | FuncType (ins, out) -> vs7 (-0x20); stack_type ins; stack_type out

    let limits vu {min; max} =
      bool (max <> None); vu min; opt vu max

    let table_type = function
      | TableType (lim, t) -> elem_type t; limits vu32 lim

    let memory_type = function
      | MemoryType lim -> limits vu32 lim

    let mutability = function
      | Immutable -> u8 0
      | Mutable -> u8 1

    let global_type = function
      | GlobalType (t, mut) -> value_type t; mutability mut

    (* Expressions *)

    open Wasm.Source
    open Wasm.Ast
    open Wasm.Values
    open Wasm.Memory

    let op n = u8 n
    let end_ () = op 0x0b

    let memop {align; offset; _} = vu32 (Int32.of_int align); vu32 offset

    let var x = vu32 x.it

    let block_type = function
      | VarBlockType x -> vs33 x.it
      | ValBlockType None -> vs7 (-0x40)
      | ValBlockType (Some t) -> value_type t

    let rec instr e =
      if e.at <> no_region then add_to_map e.at.left.file e.at.left.line e.at.left.column 0 (pos s);

      match e.it with
      | Unreachable -> op 0x00
      | Nop -> op 0x01

      | Block (ts, es) -> op 0x02; block_type ts; list instr es; end_ ()
      | Loop (ts, es) -> op 0x03; block_type ts; list instr es; end_ ()
      | If (ts, es1, es2) ->
        op 0x04; block_type ts; list instr es1;
        if es2 <> [] then op 0x05;
        list instr es2; end_ ()

      | Br x -> op 0x0c; var x
      | BrIf x -> op 0x0d; var x
      | BrTable (xs, x) -> op 0x0e; vec var xs; var x
      | Return -> op 0x0f
      | Call x -> op 0x10; var x
      | CallIndirect x -> op 0x11; var x; u8 0x00

      | Drop -> op 0x1a
      | Select -> op 0x1b

      | LocalGet x -> op 0x20; var x
      | LocalSet x -> op 0x21; var x
      | LocalTee x -> op 0x22; var x
      | GlobalGet x -> op 0x23; var x
      | GlobalSet x -> op 0x24; var x

      | Load ({ty = I32Type; sz = None; _} as mo) -> op 0x28; memop mo
      | Load ({ty = I64Type; sz = None; _} as mo) -> op 0x29; memop mo
      | Load ({ty = F32Type; sz = None; _} as mo) -> op 0x2a; memop mo
      | Load ({ty = F64Type; sz = None; _} as mo) -> op 0x2b; memop mo
      | Load ({ty = I32Type; sz = Some (Pack8, SX); _} as mo) ->
        op 0x2c; memop mo
      | Load ({ty = I32Type; sz = Some (Pack8, ZX); _} as mo) ->
        op 0x2d; memop mo
      | Load ({ty = I32Type; sz = Some (Pack16, SX); _} as mo) ->
        op 0x2e; memop mo
      | Load ({ty = I32Type; sz = Some (Pack16, ZX); _} as mo) ->
        op 0x2f; memop mo
      | Load {ty = I32Type; sz = Some (Pack32, _); _} ->
        assert false
      | Load ({ty = I64Type; sz = Some (Pack8, SX); _} as mo) ->
        op 0x30; memop mo
      | Load ({ty = I64Type; sz = Some (Pack8, ZX); _} as mo) ->
        op 0x31; memop mo
      | Load ({ty = I64Type; sz = Some (Pack16, SX); _} as mo) ->
        op 0x32; memop mo
      | Load ({ty = I64Type; sz = Some (Pack16, ZX); _} as mo) ->
        op 0x33; memop mo
      | Load ({ty = I64Type; sz = Some (Pack32, SX); _} as mo) ->
        op 0x34; memop mo
      | Load ({ty = I64Type; sz = Some (Pack32, ZX); _} as mo) ->
        op 0x35; memop mo
      | Load {ty = F32Type | F64Type; sz = Some _; _} ->
        assert false

      | Store ({ty = I32Type; sz = None; _} as mo) -> op 0x36; memop mo
      | Store ({ty = I64Type; sz = None; _} as mo) -> op 0x37; memop mo
      | Store ({ty = F32Type; sz = None; _} as mo) -> op 0x38; memop mo
      | Store ({ty = F64Type; sz = None; _} as mo) -> op 0x39; memop mo
      | Store ({ty = I32Type; sz = Some Pack8; _} as mo) -> op 0x3a; memop mo
      | Store ({ty = I32Type; sz = Some Pack16; _} as mo) -> op 0x3b; memop mo
      | Store {ty = I32Type; sz = Some Pack32; _} -> assert false
      | Store ({ty = I64Type; sz = Some Pack8; _} as mo) -> op 0x3c; memop mo
      | Store ({ty = I64Type; sz = Some Pack16; _} as mo) -> op 0x3d; memop mo
      | Store ({ty = I64Type; sz = Some Pack32; _} as mo) -> op 0x3e; memop mo
      | Store {ty = F32Type | F64Type; sz = Some _; _} -> assert false

      | MemorySize -> op 0x3f; u8 0x00
      | MemoryGrow -> op 0x40; u8 0x00

      | Const {it = I32 c; _} -> op 0x41; vs32 c
      | Const {it = I64 c; _} -> op 0x42; vs64 c
      | Const {it = F32 c; _} -> op 0x43; f32 c
      | Const {it = F64 c; _} -> op 0x44; f64 c

      | Test (I32 I32Op.Eqz) -> op 0x45
      | Test (I64 I64Op.Eqz) -> op 0x50
      | Test (F32 _) -> assert false
      | Test (F64 _) -> assert false

      | Compare (I32 I32Op.Eq) -> op 0x46
      | Compare (I32 I32Op.Ne) -> op 0x47
      | Compare (I32 I32Op.LtS) -> op 0x48
      | Compare (I32 I32Op.LtU) -> op 0x49
      | Compare (I32 I32Op.GtS) -> op 0x4a
      | Compare (I32 I32Op.GtU) -> op 0x4b
      | Compare (I32 I32Op.LeS) -> op 0x4c
      | Compare (I32 I32Op.LeU) -> op 0x4d
      | Compare (I32 I32Op.GeS) -> op 0x4e
      | Compare (I32 I32Op.GeU) -> op 0x4f

      | Compare (I64 I64Op.Eq) -> op 0x51
      | Compare (I64 I64Op.Ne) -> op 0x52
      | Compare (I64 I64Op.LtS) -> op 0x53
      | Compare (I64 I64Op.LtU) -> op 0x54
      | Compare (I64 I64Op.GtS) -> op 0x55
      | Compare (I64 I64Op.GtU) -> op 0x56
      | Compare (I64 I64Op.LeS) -> op 0x57
      | Compare (I64 I64Op.LeU) -> op 0x58
      | Compare (I64 I64Op.GeS) -> op 0x59
      | Compare (I64 I64Op.GeU) -> op 0x5a

      | Compare (F32 F32Op.Eq) -> op 0x5b
      | Compare (F32 F32Op.Ne) -> op 0x5c
      | Compare (F32 F32Op.Lt) -> op 0x5d
      | Compare (F32 F32Op.Gt) -> op 0x5e
      | Compare (F32 F32Op.Le) -> op 0x5f
      | Compare (F32 F32Op.Ge) -> op 0x60

      | Compare (F64 F64Op.Eq) -> op 0x61
      | Compare (F64 F64Op.Ne) -> op 0x62
      | Compare (F64 F64Op.Lt) -> op 0x63
      | Compare (F64 F64Op.Gt) -> op 0x64
      | Compare (F64 F64Op.Le) -> op 0x65
      | Compare (F64 F64Op.Ge) -> op 0x66

      | Unary (I32 I32Op.Clz) -> op 0x67
      | Unary (I32 I32Op.Ctz) -> op 0x68
      | Unary (I32 I32Op.Popcnt) -> op 0x69

      | Unary (I64 I64Op.Clz) -> op 0x79
      | Unary (I64 I64Op.Ctz) -> op 0x7a
      | Unary (I64 I64Op.Popcnt) -> op 0x7b

      | Unary (F32 F32Op.Abs) -> op 0x8b
      | Unary (F32 F32Op.Neg) -> op 0x8c
      | Unary (F32 F32Op.Ceil) -> op 0x8d
      | Unary (F32 F32Op.Floor) -> op 0x8e
      | Unary (F32 F32Op.Trunc) -> op 0x8f
      | Unary (F32 F32Op.Nearest) -> op 0x90
      | Unary (F32 F32Op.Sqrt) -> op 0x91

      | Unary (F64 F64Op.Abs) -> op 0x99
      | Unary (F64 F64Op.Neg) -> op 0x9a
      | Unary (F64 F64Op.Ceil) -> op 0x9b
      | Unary (F64 F64Op.Floor) -> op 0x9c
      | Unary (F64 F64Op.Trunc) -> op 0x9d
      | Unary (F64 F64Op.Nearest) -> op 0x9e
      | Unary (F64 F64Op.Sqrt) -> op 0x9f

      | Binary (I32 I32Op.Add) -> op 0x6a
      | Binary (I32 I32Op.Sub) -> op 0x6b
      | Binary (I32 I32Op.Mul) -> op 0x6c
      | Binary (I32 I32Op.DivS) -> op 0x6d
      | Binary (I32 I32Op.DivU) -> op 0x6e
      | Binary (I32 I32Op.RemS) -> op 0x6f
      | Binary (I32 I32Op.RemU) -> op 0x70
      | Binary (I32 I32Op.And) -> op 0x71
      | Binary (I32 I32Op.Or) -> op 0x72
      | Binary (I32 I32Op.Xor) -> op 0x73
      | Binary (I32 I32Op.Shl) -> op 0x74
      | Binary (I32 I32Op.ShrS) -> op 0x75
      | Binary (I32 I32Op.ShrU) -> op 0x76
      | Binary (I32 I32Op.Rotl) -> op 0x77
      | Binary (I32 I32Op.Rotr) -> op 0x78

      | Binary (I64 I64Op.Add) -> op 0x7c
      | Binary (I64 I64Op.Sub) -> op 0x7d
      | Binary (I64 I64Op.Mul) -> op 0x7e
      | Binary (I64 I64Op.DivS) -> op 0x7f
      | Binary (I64 I64Op.DivU) -> op 0x80
      | Binary (I64 I64Op.RemS) -> op 0x81
      | Binary (I64 I64Op.RemU) -> op 0x82
      | Binary (I64 I64Op.And) -> op 0x83
      | Binary (I64 I64Op.Or) -> op 0x84
      | Binary (I64 I64Op.Xor) -> op 0x85
      | Binary (I64 I64Op.Shl) -> op 0x86
      | Binary (I64 I64Op.ShrS) -> op 0x87
      | Binary (I64 I64Op.ShrU) -> op 0x88
      | Binary (I64 I64Op.Rotl) -> op 0x89
      | Binary (I64 I64Op.Rotr) -> op 0x8a

      | Binary (F32 F32Op.Add) -> op 0x92
      | Binary (F32 F32Op.Sub) -> op 0x93
      | Binary (F32 F32Op.Mul) -> op 0x94
      | Binary (F32 F32Op.Div) -> op 0x95
      | Binary (F32 F32Op.Min) -> op 0x96
      | Binary (F32 F32Op.Max) -> op 0x97
      | Binary (F32 F32Op.CopySign) -> op 0x98

      | Binary (F64 F64Op.Add) -> op 0xa0
      | Binary (F64 F64Op.Sub) -> op 0xa1
      | Binary (F64 F64Op.Mul) -> op 0xa2
      | Binary (F64 F64Op.Div) -> op 0xa3
      | Binary (F64 F64Op.Min) -> op 0xa4
      | Binary (F64 F64Op.Max) -> op 0xa5
      | Binary (F64 F64Op.CopySign) -> op 0xa6

      | Convert (I32 I32Op.ExtendSI32) -> assert false
      | Convert (I32 I32Op.ExtendUI32) -> assert false
      | Convert (I32 I32Op.WrapI64) -> op 0xa7
      | Convert (I32 I32Op.TruncSF32) -> op 0xa8
      | Convert (I32 I32Op.TruncUF32) -> op 0xa9
      | Convert (I32 I32Op.TruncSF64) -> op 0xaa
      | Convert (I32 I32Op.TruncUF64) -> op 0xab
      | Convert (I32 I32Op.ReinterpretFloat) -> op 0xbc

      | Convert (I64 I64Op.ExtendSI32) -> op 0xac
      | Convert (I64 I64Op.ExtendUI32) -> op 0xad
      | Convert (I64 I64Op.WrapI64) -> assert false
      | Convert (I64 I64Op.TruncSF32) -> op 0xae
      | Convert (I64 I64Op.TruncUF32) -> op 0xaf
      | Convert (I64 I64Op.TruncSF64) -> op 0xb0
      | Convert (I64 I64Op.TruncUF64) -> op 0xb1
      | Convert (I64 I64Op.ReinterpretFloat) -> op 0xbd

      | Convert (F32 F32Op.ConvertSI32) -> op 0xb2
      | Convert (F32 F32Op.ConvertUI32) -> op 0xb3
      | Convert (F32 F32Op.ConvertSI64) -> op 0xb4
      | Convert (F32 F32Op.ConvertUI64) -> op 0xb5
      | Convert (F32 F32Op.PromoteF32) -> assert false
      | Convert (F32 F32Op.DemoteF64) -> op 0xb6
      | Convert (F32 F32Op.ReinterpretInt) -> op 0xbe

      | Convert (F64 F64Op.ConvertSI32) -> op 0xb7
      | Convert (F64 F64Op.ConvertUI32) -> op 0xb8
      | Convert (F64 F64Op.ConvertSI64) -> op 0xb9
      | Convert (F64 F64Op.ConvertUI64) -> op 0xba
      | Convert (F64 F64Op.PromoteF32) -> op 0xbb
      | Convert (F64 F64Op.DemoteF64) -> assert false
      | Convert (F64 F64Op.ReinterpretInt) -> op 0xbf

    let const c =
      list instr c.it; end_ ()

    (* Sections *)

    let section id f x needed =
      if needed then begin
        u8 id;
        let g = gap32 () in
        let p = pos s in
        f x;
        patch_gap32 g (pos s - p)
      end

    let custom_section name f x needed =
      section 0 (fun x ->
        string name;
        f x
      ) x needed

    (* Type section *)
    let type_ t = func_type t.it

    let type_section ts =
      section 1 (vec type_) ts (ts <> [])

    (* Import section *)
    let import_desc d =
      match d.it with
      | FuncImport x -> u8 0x00; var x
      | TableImport t -> u8 0x01; table_type t
      | MemoryImport t -> u8 0x02; memory_type t
      | GlobalImport t -> u8 0x03; global_type t

    let import im =
      let {module_name; item_name; idesc} = im.it in
      name module_name; name item_name; import_desc idesc

    let import_section ims =
      section 2 (vec import) ims (ims <> [])

    (* Function section *)
    let func f = var f.it.ftype

    let func_section fs =
      section 3 (vec func) fs (fs <> [])

    (* Table section *)
    let table tab =
      let {ttype} = tab.it in
      table_type ttype

    let table_section tabs =
      section 4 (vec table) tabs (tabs <> [])

    (* Memory section *)
    let memory mem =
      let {mtype} = mem.it in
      memory_type mtype

    let memory_section mems =
      section 5 (vec memory) mems (mems <> [])

    (* Global section *)
    let global g =
      let {gtype; value} = g.it in
      global_type gtype; const value

    let global_section gs =
      section 6 (vec global) gs (gs <> [])

    (* Export section *)
    let export_desc d =
      match d.it with
      | FuncExport x -> u8 0; var x
      | TableExport x -> u8 1; var x
      | MemoryExport x -> u8 2; var x
      | GlobalExport x -> u8 3; var x

    let export ex =
      let {name = n; edesc} = ex.it in
      name n; export_desc edesc

    let export_section exs =
      section 7 (vec export) exs (exs <> [])

    (* Start section *)
    let start_section xo =
      section 8 (opt var) xo (xo <> None)

    (* Code section *)
    let compress ts =
      let combine t = function
        | (t', n) :: ts when t = t' -> (t, n + 1) :: ts
        | ts -> (t, 1) :: ts
      in List.fold_right combine ts []

    let local (t, n) = len n; value_type t

    let code f =
      let {locals; body; _} = f.it in
      let g = gap32 () in
      let p = pos s in
      vec local (compress locals);
      list instr body;
      end_ ();
      patch_gap32 g (pos s - p)

    let code_section fs =
      section 10 (vec code) fs (fs <> [])

    (* Element section *)
    let segment dat seg =
      let {index; offset; init} = seg.it in
      var index; const offset; dat init

    let table_segment seg =
      segment (vec var) seg

    let elem_section elems =
      section 9 (vec table_segment) elems (elems <> [])

    (* Data section *)
    let memory_segment seg =
      segment string seg

    let data_section data =
      section 11 (vec memory_segment) data (data <> [])

    (* DFINITY Types section *)

    (*
    The dfinity types are specified in terms of function ids excluding
    imports, which is unidiomatic. We use real function ids internally,
    so we have to work around it here.
    *)
    let count_fun_imports (em : extended_module) =
      let is_fun_import imp = match imp.it.idesc.it with
            | FuncImport _ -> true
            | _ -> false in
      Lib.List32.length (List.filter is_fun_import em.module_.imports)

    let dfinity_type = function
        | CustomModule.I32      -> vu32 0x7fl
        | CustomModule.DataBuf  -> vu32 0x6cl
        | CustomModule.ElemBuf  -> vu32 0x6bl
        | CustomModule.ActorRef -> vu32 0x6fl
        | CustomModule.FuncRef  -> vu32 0x6dl

    let dfinity_fun_type (_fi, param_types) =
      vu32 0x60l; (* function type op code *)
      vec dfinity_type param_types;
      vu32 0l

    let dfinity_fun_type_map ni i (fi, _param_types) =
      vu32 (Int32.sub fi ni);
      vu32 (Int32.of_int i)

    let dfinity_types_section ni tys =
      (* We could deduplicate the types here *)
      custom_section "types" (vec dfinity_fun_type) tys (tys <> []);
      custom_section "typeMap" (veci (dfinity_fun_type_map ni)) tys (tys <> [])

    (* DFINITY Persist section *)

    let dfinity_persist_global (i, sort) =
      vu32 0x03l; (* a global *)
      vu32 i; (* the index *)
      dfinity_type sort

    let dfinity_persist_section pgs =
      custom_section "persist" (vec dfinity_persist_global) pgs (pgs <> [])

    (* Name section *)

    let assoc_list : 'a. ('a -> unit) -> (int32 * 'a) list -> unit = fun f xs ->
      vec (fun (li, x) -> vu32 li; f x)
          (List.sort (fun (i1,_) (i2,_) -> compare i1 i2) xs)

    let name_section_body (ns : name_section) =
      (* module name section *)
      section 0 (opt string) ns.module_ (ns.module_ <> None);
      (* function names section *)
      section 1 (assoc_list string) ns.function_names  (ns.function_names <> []);
      (* locals names section *)
      section 2 (assoc_list (assoc_list string)) ns.locals_names  (ns.locals_names <> [])

    let name_section ns =
      custom_section "name" name_section_body ns
        (ns.module_ <> None || ns.function_names <> [] || ns.locals_names <> [])

    (* Module *)

    let module_ (em : extended_module) =
      let m = em.module_ in

      u32 0x6d736100l;
      u32 version;
      (* no use-case for encoding dylink section yet, but here would be the place *)
      assert (em.dylink = None);
      type_section m.types;
      import_section m.imports;
      func_section m.funcs;
      table_section m.tables;
      memory_section m.memories;
      global_section m.globals;
      export_section m.exports;
      start_section m.start;
      elem_section m.elems;
      code_section m.funcs;
      data_section m.data;
      (* other optional sections *)
      dfinity_types_section (count_fun_imports em) em.types;
      dfinity_persist_section em.persist;
      name_section em.name;
  end
  in E.module_ em;

  let mappings = Buffer.contents map in
  let n = max 0 ((String.length mappings) - 1) in
  let json : Yojson.Basic.t = `Assoc [
    ("version", `Int 3);
    ("sources", `List ( List.map (fun x -> `String x) !sources ) );
    ("sourcesContent", `List ( List.map (fun x -> if x = "" then `Null else `String x) !sourcesContent ) );
    ("mappings", `String (String.sub mappings 0 n) )
  ] in

  (Yojson.Basic.to_string json, to_string s)