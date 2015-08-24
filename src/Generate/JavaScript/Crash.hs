module Generate.JavaScript.Crash where

import qualified Language.ECMAScript3.Syntax as JS

import Generate.JavaScript.Helpers (ref)
import qualified Reporting.Crash as Crash


crash :: Crash.Details -> JS.Expression ()
crash _details =
  ref "undefined"
