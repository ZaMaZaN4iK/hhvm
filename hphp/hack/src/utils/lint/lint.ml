(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Hh_core
open Utils

(* These severity levels are based on those provided by Arcanist. "Advice"
 * means notify the user of the lint without requiring confirmation if the lint
 * is benign; "Warning" will raise a confirmation prompt if the lint applies to
 * a line that was changed in the given diff; and "Error" will always raise a
 * confirmation prompt, regardless of where the lint occurs in the file. *)
type severity =
  | Lint_error
  | Lint_warning
  | Lint_advice

let string_of_severity = function
  | Lint_error -> "error"
  | Lint_warning -> "warning"
  | Lint_advice -> "advice"

type 'a t = {
  code : int;
  severity : severity;
  pos : 'a Pos.pos;
  message : string;
  (* Normally, lint warnings and lint advice only get shown by arcanist if the
   * lines they are raised on overlap with lines changed in a diff. This
   * flag bypasses that behavior *)
  bypass_changed_lines : bool;
  autofix : (string * string)
}

let (lint_list: Relative_path.t t list option ref) = ref None

let get_code {code; _} = code
let get_pos {pos; _} = pos

let add
  ?(bypass_changed_lines=false)
  ?(autofix=("", ""))
  code
  severity
  pos
  message =
  match !lint_list with
    | Some lst ->
      if !Errors.is_hh_fixme pos code then () else begin
        let lint =
          { code; severity; pos; message; bypass_changed_lines; autofix } in
        lint_list := Some (lint :: lst)
      end
    (* by default, we ignore lint errors *)
    | None -> ()

let to_absolute ({pos; _} as lint) =
  {lint with pos = Pos.to_absolute pos}

let to_string lint =
  let code = Errors.error_code_to_string lint.code in
  Printf.sprintf "%s\n%s (%s)" (Pos.string lint.pos) lint.message code

let to_json {pos; code; severity; message; bypass_changed_lines;
    autofix=(original, replacement)} =
  let line, scol, ecol = Pos.info_pos pos in
  Hh_json.JSON_Object [
      "descr", Hh_json.JSON_String message;
      "severity", Hh_json.JSON_String (string_of_severity severity);
      "path",  Hh_json.JSON_String (Pos.filename pos);
      "line",  Hh_json.int_ line;
      "start", Hh_json.int_ scol;
      "end",   Hh_json.int_ ecol;
      "code",  Hh_json.int_ code;
      "bypass_changed_lines", Hh_json.JSON_Bool bypass_changed_lines;
      "original", Hh_json.JSON_String original;
      "replacement", Hh_json.JSON_String replacement;
  ]

module Codes = struct
  let lowercase_constant                    = 5001 (* DONT MODIFY!!!! *)
  let use_collection_literal                = 5002 (* DONT MODIFY!!!! *)
  let static_string                         = 5003 (* DONT MODIFY!!!! *)
  let shape_idx_required_field              = 5005 (* DONT MODIFY!!!! *)

  (* Values 5501 - 5999 are reserved for FB-internal use *)

  (* EXTEND HERE WITH NEW VALUES IF NEEDED *)
end

let internal_error pos msg =
  add 0 Lint_error pos ("Internal error: "^msg)

let lowercase_constant pos cst =
  let lower = String.lowercase_ascii cst in
  add Codes.lowercase_constant Lint_warning pos
    (spf "Please use '%s' instead of '%s'" lower cst)

let use_collection_literal pos coll =
  let coll = strip_ns coll in
  add Codes.use_collection_literal Lint_warning pos
    (spf "Use `%s {...}` instead of `new %s(...)`" coll coll)

let static_string ?(no_consts=false) pos =
  add Codes.static_string Lint_warning pos begin
    if no_consts
    then
      "This should be a string literal so that lint can analyze it."
    else
      "This should be a string literal or string constant so that lint can "^
      "analyze it."
  end

let shape_idx_access_required_field field_pos name =
  add Codes.shape_idx_required_field Lint_warning field_pos
    ("The field '"^name^"' is required to exist in the shape. Consider using a \
    subscript-expression instead, such as $myshape['"^name^"']")

let do_ f =
  let list_copy = !lint_list in
  lint_list := Some [];
  let result = f () in
  let out = match !lint_list with
    | Some lst -> lst
    | None -> assert false in
  lint_list := list_copy;
  List.rev out, result
