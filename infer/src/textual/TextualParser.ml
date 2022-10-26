(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format
module L = Logging

type error = VerificationError of TextualVerification.error | SyntaxError of string

let pp_error sourcefile fmt = function
  | VerificationError err ->
      TextualVerification.pp_error sourcefile fmt err
  | SyntaxError err ->
      F.fprintf fmt "%s" err


let parse_buf sourcefile filebuf =
  try
    let lexer = TextualLexer.main in
    let m = TextualMenhir.main lexer filebuf sourcefile in
    let errors = TextualVerification.run m in
    if List.is_empty errors then Ok m else Error (List.map errors ~f:(fun x -> VerificationError x))
  with TextualMenhir.Error ->
    let pos = filebuf.Lexing.lex_curr_p in
    let buf_length = Lexing.lexeme_end filebuf - Lexing.lexeme_start filebuf in
    let line = pos.Lexing.pos_lnum in
    let col = pos.Lexing.pos_cnum - pos.Lexing.pos_bol - buf_length in
    let err_msg =
      sprintf "SIL syntax error in file %s at line %d, column %d.\n%!"
        (SourceFile.to_string sourcefile) line col
    in
    Error [SyntaxError err_msg]


let parse_string sourcefile text =
  let filebuf = Lexing.from_string text in
  parse_buf sourcefile filebuf


let parse_chan sourcefile ic =
  let filebuf = Lexing.from_channel ic in
  parse_buf sourcefile filebuf


module TextualFile = struct
  type t = StandaloneFile of string | TranslatedFile of {source_path: string; textual_path: string}

  let source_path = function
    | StandaloneFile path ->
        path
    | TranslatedFile {source_path; _} ->
        source_path


  let content_path = function
    | StandaloneFile path ->
        path
    | TranslatedFile {textual_path; _} ->
        textual_path
end

let parse textual_file =
  let sourcefile = SourceFile.create (TextualFile.source_path textual_file) in
  let textual_path = TextualFile.content_path textual_file in
  let cin = In_channel.create textual_path in
  let result =
    let print_errors errs = List.iter errs ~f:(L.external_error "%a" (pp_error sourcefile)) in
    parse_chan sourcefile cin |> Result.map_error ~f:print_errors
  in
  In_channel.close cin ;
  result


let capture textual_paths =
  List.iter textual_paths ~f:(fun textual_path ->
      match parse textual_path with
      | Error _ ->
          ()
      | Ok module_ -> (
          let source_file = module_.sourcefile in
          DB.Results_dir.init source_file ;
          try
            let cfg, tenv = TextualSil.module_to_sil module_ in
            SourceFiles.add source_file cfg (FileLocal tenv) None ;
            if Config.debug_mode then Tenv.store_debug_file_for_source source_file tenv ;
            if
              Config.debug_mode || Config.testing_mode || Config.frontend_tests
              || Option.is_some Config.icfg_dotty_outfile
            then DotCfg.emit_frontend_cfg source_file cfg ;
            Tenv.store_global tenv ;
            ()
          with Textual.ToSilTransformationError pp ->
            L.external_error
              "%s: conversion from Textual to SIL failed because of an unsupported form\n  %a\n"
              (Filename.basename (SourceFile.to_rel_path source_file))
              pp () ) )