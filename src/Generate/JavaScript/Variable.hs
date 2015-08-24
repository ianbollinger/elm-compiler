module Generate.JavaScript.Variable where

import qualified AST.Helpers as Help
import qualified AST.Module as Module
import qualified AST.Variable as Var
import qualified Data.List as List
import qualified Data.Set as Set
import qualified Generate.JavaScript.Helpers as JS
import qualified Language.ECMAScript3.Syntax as JS


-- CANONICAL NAMES

value :: Module.Name -> String -> JS.Expression ()
value home name =
    canonical (Var.Canonical (Var.Module home) name)


canonical :: Var.Canonical -> JS.Expression ()
canonical (Var.Canonical home name) =
  let
    prefix =
      case home of
        Var.Local ->
            ""

        Var.BuiltIn ->
            ""

        Var.Module moduleName ->
            '$' : List.intercalate "$" moduleName
  in
    if Help.isOp name then
        JS.BracketRef () (JS.ref (prefix ++ "$_op")) (JS.StringLit () name)
    else
        JS.ref (prefix ++ "$" ++ safe name)


-- SAFE NAMES

safe :: String -> String
safe name =
  let
    saferName =
      if Set.member name jsReserveds then '$' : name else name
  in
      map (swap '\'' '$') saferName


swap :: Char -> Char -> Char -> Char
swap from to c =
  if c == from then to else c


jsReserveds :: Set.Set String
jsReserveds =
  Set.fromList
    [ "null", "undefined", "NaN", "Infinity", "true", "false", "eval"
    , "arguments", "int", "byte", "char", "goto", "long", "final", "float"
    , "short", "double", "native", "throws", "boolean", "abstract", "volatile"
    , "transient", "synchronized", "function", "break", "case", "catch"
    , "continue", "debugger", "default", "delete", "do", "else", "finally"
    , "for", "function", "if", "in", "instanceof", "new", "return", "switch"
    , "this", "throw", "try", "typeof", "var", "void", "while", "with", "class"
    , "const", "enum", "export", "extends", "import", "super", "implements"
    , "interface", "let", "package", "private", "protected", "public"
    , "static", "yield"
    -- reserved by the Elm runtime system
    , "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9"
    , "A2", "A3", "A4", "A5", "A6", "A7", "A8", "A9"
    ]
