module Generate.JavaScript.Expression where

import Control.Applicative ((<$>),(<*>))
import Control.Arrow (second)
import Control.Monad.State
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import Language.ECMAScript3.Syntax

import AST.Expression.General as Expr
import qualified AST.Expression.Optimized as Opt
import qualified AST.Helpers as Help
import qualified AST.Literal as L
import qualified AST.Pattern as P
import qualified AST.Variable as Var
import Generate.JavaScript.Helpers as Help
import qualified Generate.JavaScript.BuiltIn as BuiltIn
import qualified Generate.JavaScript.Crash as Crash
import qualified Generate.JavaScript.Literal as Literal
import qualified Generate.JavaScript.Variable as Var
import qualified Optimize.Cases as Case
import qualified Reporting.Annotation as A
import qualified Reporting.Crash as Crash


-- CODE CHUNKS

data Code
    = JsExpr (Expression ())
    | JsBlock [Statement ()]


jsExpr :: Expression () -> State Int Code
jsExpr exp =
  return (JsExpr exp)


jsBlock :: [Statement ()] -> State Int Code
jsBlock exp =
  return (JsBlock exp)


isBlock :: Code -> Bool
isBlock code =
  case code of
    JsBlock _ -> True
    JsExpr _ -> False


toStatementList :: Code -> [Statement ()]
toStatementList code =
  case code of
    JsExpr expr ->
        [ ret expr ]
    JsBlock stmts ->
        stmts


toStatement :: Code -> Statement ()
toStatement code =
  case code of
    JsExpr expr ->
        ret expr
    JsBlock [stmt] ->
        stmt
    JsBlock stmts ->
        BlockStmt () stmts


toExpr :: Code -> Expression ()
toExpr code =
  case code of
    JsExpr expr ->
        expr
    JsBlock stmts ->
        function [] stmts `call` []


-- TAIL CALL CONTEXT

type TailCallContext =
  Maybe (String, [String], Label)


type Label =
  Id ()


-- EXPRESSIONS

toJsExpr :: Opt.Expr -> State Int (Expression ())
toJsExpr =
  exprToJsExpr Nothing


toCode :: Opt.Expr -> State Int Code
toCode =
  exprToCode Nothing


exprToJsExpr :: TailCallContext -> Opt.Expr -> State Int (Expression ())
exprToJsExpr tcc canonicalExpr =
  toExpr <$> exprToCode tcc canonicalExpr


exprToCode :: TailCallContext -> Opt.Expr -> State Int Code
exprToCode tcc annotatedExpr@(A.A _ expr) =
  case expr of
    Var var ->
        jsExpr (Var.canonical var)

    Literal lit ->
        jsExpr (Literal.literal lit)

    Range low high ->
        do  jsLow <- toJsExpr low
            jsHigh <- toJsExpr high
            jsExpr $ BuiltIn.range jsLow jsHigh

    Access record field ->
        do  record' <- toJsExpr record
            jsExpr $ DotRef () record' (var (Var.safe field))

    Update record fields ->
        let
          fieldToJs (field, value) =
            do  jsValue <- toJsExpr value
                return (Var.safe field, jsValue)
        in
          do  jsRecord <- toJsExpr record
              jsFields <- mapM fieldToJs fields
              jsExpr $ BuiltIn.recordUpdate jsRecord jsFields

    Record fields ->
        let
          fieldToJs (field, value) =
            (,) (prop (Var.safe field)) <$> toJsExpr value
        in
          do  jsFields <- mapM fieldToJs fields
              jsExpr $ ObjectLit () jsFields

    Binop op leftExpr rightExpr ->
        binop op leftExpr rightExpr

    Lambda _ _ ->
        generateFunction (Expr.collectLambdas annotatedExpr)

    App _ _ ->
        generateApplication tcc annotatedExpr

    Let defs body ->
        generateLet tcc defs body

    MultiIf branches finally ->
        generateIf tcc branches finally

    Case expr branches ->
        generateCase tcc expr branches

    ExplicitList elements ->
        do  jsElements <- mapM toJsExpr elements
            jsExpr $ BuiltIn.list jsElements

    Data tag members ->
        do  jsMembers <- mapM toJsExpr members
            jsExpr $ ObjectLit () (ctor : fields jsMembers)
        where
          ctor = (prop "ctor", StringLit () tag)
          fields =
              zipWith (\n e -> (prop ("_" ++ show n), e)) [ 0 :: Int .. ]

    GLShader _uid src _tipe ->
        jsExpr $ ObjectLit () [(PropString () "src", Literal.literal (L.Str src))]

    Port impl ->
        error "TODO" impl
{--
        case impl of
          In name portType ->
              jsExpr (Port.inbound name portType)

          Out name expr portType ->
              do  expr' <- toJsExpr expr
                  jsExpr (Port.outbound name expr' portType)

          Task name expr portType ->
              do  expr' <- toJsExpr expr
                  jsExpr (Port.task name expr' portType)
--}

    Crash details ->
        jsExpr $ Crash.crash details


-- FUNCTIONS

generateFunction :: ([P.Optimized], Opt.Expr) -> State Int Code
generateFunction (args, initialBody) =
  do  (argVars, patternDefs) <- destructuredArgs args
      code <- generateLet Nothing patternDefs initialBody
      jsExpr (generateFunctionWithArity argVars code)


generateTailFunction :: String -> ([P.Optimized], Opt.Expr) -> State Int (Expression ())
generateTailFunction name (args, initialBody) =
  do  (argVars, patternDefs) <- destructuredArgs args
      label <- Id () <$> Case.newVar
      code <- generateLet (Just (name, argVars, label)) patternDefs initialBody
      let whileLoop =
            JsBlock [ LabelledStmt () label (WhileStmt () (BoolLit () True) (toStatement code)) ]
      return (generateFunctionWithArity argVars whileLoop)


generateFunctionWithArity :: [String] -> Code -> Expression ()
generateFunctionWithArity args code =
    let
        arity = length args
    in
      if 2 <= arity && arity <= 9 then
          let
              fN = "F" ++ show arity
          in
              ref fN <| function args (toStatementList code)
      else
          let
              (lastArg:otherArgs) = reverse args
              innerBody = function [lastArg] (toStatementList code)
          in
              foldl (\body arg -> function [arg] [ret body]) innerBody otherArgs


destructuredArgs :: [P.Optimized] -> State Int ([String], [Opt.Def])
destructuredArgs args =
  do  (argVars, maybePatternDefs) <- unzip <$> mapM destructPattern args
      return (argVars, Maybe.catMaybes maybePatternDefs)


destructPattern :: P.Optimized -> State Int (String, Maybe Opt.Def)
destructPattern pattern@(A.A ann pat) =
  case pat of
    P.Var x ->
        return (Var.safe x, Nothing)

    _ ->
        do  arg <- Case.newVar
            return
              ( arg
              , Just $ Opt.Definition Opt.dummyFacts pattern (A.A ann (localVar arg))
              )


-- APPLICATIONS

generateApplication :: TailCallContext -> Opt.Expr -> State Int Code
generateApplication tcc expr =
  let
    (func:args) =
      Expr.collectApps expr

    arity =
      length args

    reassign name tempName =
      ExprStmt () (AssignExpr () OpAssign (LVar () name) (ref tempName))

    aN =
      "A" ++ show arity
  in
    case isTailCall tcc func arity of
      Just (argNames, label) ->
        do  args' <- mapM toJsExpr args
            tempNames <- mapM (\_ -> Case.newVar) args
            jsBlock $
              VarDeclStmt () (zipWith varDecl tempNames args')
              : zipWith reassign argNames tempNames
              ++ [ContinueStmt () (Just label)]

      _ ->
        do  func' <- toJsExpr func
            args' <- mapM toJsExpr args
            jsExpr $
              if 2 <= arity && arity <= 9 then
                ref aN `call` (func':args')
              else
                foldl1 (<|) (func':args')


isTailCall :: TailCallContext -> Opt.Expr -> Int -> Maybe ([String], Label)
isTailCall tcc (A.A _ func) arity =
  case (func, tcc) of
    (Var (Var.Canonical Var.Local name), Just (tcName, tcArgs, tcLabel)) ->
        if name == tcName && length tcArgs == arity then
          Just (tcArgs, tcLabel)
        else
          Nothing

    _ ->
      Nothing


-- LET EXPRESSIONS

generateLet
    :: TailCallContext
    -> [Opt.Def]
    -> Opt.Expr
    -> State Int Code
generateLet tcc givenDefs givenBody =
  do  let (defs, body) = flattenLets givenDefs givenBody
      stmts <- concat <$> mapM defToStatements defs
      code <- exprToCode tcc body
      jsBlock (stmts ++ toStatementList code)


flattenLets :: [Opt.Def] -> Opt.Expr -> ([Opt.Def], Opt.Expr)
flattenLets defs lexpr@(A.A _ expr) =
  case expr of
    Let ds body ->
        flattenLets (defs ++ ds) body

    _ ->
        (defs, lexpr)


-- GENERATE IFS

generateIf :: TailCallContext -> [(Opt.Expr, Opt.Expr)] -> Opt.Expr -> State Int Code
generateIf tcc givenBranches givenFinally =
  let
    (branches, finally) =
        crushIfs givenBranches givenFinally

    convertBranch (condition, expr) =
        (,) <$> toJsExpr condition <*> exprToCode tcc expr

    ifExpression (condition, branch) otherwise =
        CondExpr () condition branch otherwise

    ifStatement (condition, branch) otherwise =
        IfStmt () condition branch otherwise
  in
    do  jsBranches <- mapM convertBranch branches
        jsFinally <- exprToCode tcc finally

        if any isBlock (jsFinally : map snd jsBranches)
          then
            jsBlock [ foldr ifStatement (toStatement jsFinally) (map (second toStatement) jsBranches) ]
          else
            jsExpr (foldr ifExpression (toExpr jsFinally) (map (second toExpr) jsBranches))


crushIfs
    :: [(Opt.Expr, Opt.Expr)]
    -> Opt.Expr
    -> ([(Opt.Expr, Opt.Expr)], Opt.Expr)
crushIfs branches finally =
  crushIfsHelp [] branches finally


crushIfsHelp
    :: [(Opt.Expr, Opt.Expr)]
    -> [(Opt.Expr, Opt.Expr)]
    -> Opt.Expr
    -> ([(Opt.Expr, Opt.Expr)], Opt.Expr)
crushIfsHelp visitedBranches unvisitedBranches finally =
  case unvisitedBranches of
    [] ->
        case finally of
          A.A _ (MultiIf subBranches subFinally) ->
              crushIfsHelp visitedBranches subBranches subFinally

          _ ->
              (reverse visitedBranches, finally)

    (A.A _ (Literal (L.Boolean True)), branch) : _ ->
        crushIfsHelp visitedBranches [] branch

    (A.A _ (Var (Var.Canonical (Var.Module ["Basics"]) "otherwise")), branch) : _ ->
        crushIfsHelp visitedBranches [] branch

    visiting : unvisited ->
        crushIfsHelp (visiting : visitedBranches) unvisited finally



-- DEFINITIONS

defToStatements :: Opt.Def -> State Int [Statement ()]
defToStatements (Opt.Definition facts pattern expr) =
    case Opt.tailRecursionDetails facts of
      Just name ->
          do  func <- generateTailFunction name (Expr.collectLambdas expr)
              return [ VarDeclStmt () [ varDecl name func ] ]

      Nothing ->
          defToStatementsHelp facts pattern =<< toJsExpr expr


defToStatementsHelp
    :: Opt.Facts
    -> P.Optimized
    -> Expression ()
    -> State Int [Statement ()]
defToStatementsHelp facts annPattern@(A.A _ pattern) jsExpr =
  let
    define x =
      varDecl x jsExpr
  in
  case pattern of
    P.Var x ->
        if Help.isOp x then
            let
                op = LBracket () (ref "_op") (StringLit () x)
            in
                return [ ExprStmt () $ AssignExpr () OpAssign op jsExpr ]
        else
            return [ VarDeclStmt () [ define (Var.safe x) ] ]

    P.Record fields ->
        let
            setField name =
                varDecl name (obj ["$",name])
        in
            return [ VarDeclStmt () (define "$" : map setField fields) ]

    P.Data (Var.Canonical _ name) patterns | vars /= Nothing ->
        return [ VarDeclStmt () (setup (zipWith decl (maybe [] id vars) [0..])) ]
      where
        vars = getVars patterns
        getVars patterns =
            case patterns of
              A.A _ (P.Var x) : rest ->
                  (Var.safe x :) `fmap` getVars rest
              [] ->
                  Just []
              _ ->
                  Nothing

        decl x n = varDecl x (obj ["$","_" ++ show n])
        setup vars
            | Help.isTuple name = define "$" : vars
            | otherwise = define "_raw" : safeAssign : vars

        safeAssign = varDecl "$" (CondExpr () if' (ref "_raw") exception)
        if' = InfixExpr () OpStrictEq (obj ["_raw","ctor"]) (StringLit () name)
        exception = Crash.crash (Crash.IncompletePatternMatch (error "TODO"))

    _ ->
        do  defs' <- concat <$> mapM toDef vars
            return (VarDeclStmt () [define "_"] : defs')
        where
          vars = P.boundVarList annPattern
          mkVar = A.A () . localVar
          toDef y =
            let expr = A.A () $ Case (mkVar "_") [(annPattern, mkVar y)]
                pat = A.A () (P.Var y)
            in
                defToStatements (Opt.Definition facts pat expr)


-- CASE EXPRESSIONS

generateCase :: TailCallContext -> Opt.Expr -> [(P.Optimized, Opt.Expr)] -> State Int Code
generateCase tcc expr branches =
  do  (tempVar, initialMatch) <-
          Case.toMatch branches

      (revisedMatch, stmt) <-
          case expr of
            A.A _ (Var (Var.Canonical Var.Local x)) ->
                return (Case.matchSubst [(tempVar, Var.safe x)] initialMatch, [])
            _ ->
                do  expr' <- toJsExpr expr
                    return (initialMatch, [VarDeclStmt () [varDecl tempVar expr']])

      match' <- match tcc revisedMatch

      jsBlock (stmt ++ match')


match :: TailCallContext -> Case.Match -> State Int [Statement ()]
match tcc mtch =
  case mtch of
    Case.Match name clauses mtch' ->
        do  (isChars, clauses') <- unzip <$> mapM (clause tcc name) clauses
            mtch'' <- match tcc mtch'
            return (SwitchStmt () (format isChars (access name)) clauses' : mtch'')
        where
          isLiteral p =
            case p of
              Case.Clause (Right _) _ _ ->
                  True
              _ ->
                  False

          access name =
              if any isLiteral clauses then
                  obj [name]
              else
                  obj (Help.splitDots name ++ ["ctor"])

          format isChars expr =
              if or isChars then
                  InfixExpr () OpAdd expr (StringLit () "")
              else
                  expr

    Case.Fail ->
        return [ ExprStmt () (Crash.crash (Crash.IncompletePatternMatch (error "TODO"))) ]

    Case.Break ->
        return [BreakStmt () Nothing]

    Case.Other expr ->
        toStatementList <$> exprToCode tcc expr

    Case.Seq ms ->
        concat <$> mapM (match tcc) (dropEnd [] ms)
      where
        dropEnd acc [] = acc
        dropEnd acc (m:ms) =
            case m of
              Case.Other _ -> acc ++ [m]
              _ -> dropEnd (acc ++ [m]) ms


clause :: TailCallContext -> String -> Case.Clause -> State Int (Bool, CaseClause ())
clause tcc variable (Case.Clause value vars mtch) =
  do  statemens <- match tcc (Case.matchSubst (zip vars vars') mtch)
      return ((,) isChar (CaseClause () pattern statemens))
  where
    vars' =
        map (\n -> variable ++ "._" ++ show n) [0..]

    (isChar, pattern) =
        case value of
          Right (L.Chr c) ->
            (True, StringLit () [c])

          _ ->
            (,) False $
              case value of
                Right (L.Boolean b) ->
                    BoolLit () b

                Right lit ->
                    Literal.literal lit

                Left (Var.Canonical _ name) ->
                    StringLit () name


-- BINARY OPERATORS

binop
    :: Var.Canonical
    -> Opt.Expr
    -> Opt.Expr
    -> State Int Code
binop func left right
  | func == Var.Canonical Var.BuiltIn "::" =
      toCode (A.A () (Data "::" [left,right]))

  | func == forwardCompose =
      compose (collectLeftAssoc forwardCompose left right)

  | func == backwardCompose =
      compose (collectRightAssoc backwardCompose left right)

  | func == forwardApply =
      pipe (collectLeftAssoc forwardApply left right)

  | func == backwardApply =
      pipe (collectRightAssoc backwardApply left right)

  | otherwise =
      do  jsLeft <- toJsExpr left
          jsRight <- toJsExpr right
          jsExpr (makeExpr func jsLeft jsRight)


-- CONTROL FLOW OPERATOR HELPERS

apply :: Expression () -> Expression () -> Expression ()
apply arg func =
  func <| arg


compose :: [Opt.Expr] -> State Int Code
compose functions =
  do  jsFunctions <- mapM toJsExpr functions
      jsExpr $ ["$"] ==> List.foldl' apply (ref "$") jsFunctions


pipe :: [Opt.Expr] -> State Int Code
pipe expressions =
  do  (value:functions) <- mapM toJsExpr expressions
      jsExpr $ List.foldl' apply value functions


forwardCompose :: Var.Canonical
forwardCompose =
  inBasics ">>"


backwardCompose :: Var.Canonical
backwardCompose =
  inBasics "<<"


forwardApply :: Var.Canonical
forwardApply =
  inBasics "|>"


backwardApply :: Var.Canonical
backwardApply =
  inBasics "<|"


inBasics :: String -> Var.Canonical
inBasics name =
  Var.Canonical (Var.Module ["Basics"]) name


-- BINARY OPERATOR HELPERS

makeExpr :: Var.Canonical -> (Expression () -> Expression () -> Expression ())
makeExpr qualifiedOp@(Var.Canonical home op) =
    let
        simpleMake left right =
            ref "A2" `call` [ Var.canonical qualifiedOp, left, right ]
    in
        if home == Var.Module ["Basics"] then
            Map.findWithDefault simpleMake op basicOps
        else
            simpleMake


basicOps :: Map.Map String (Expression () -> Expression () -> Expression ())
basicOps =
    Map.fromList (infixOps ++ specialOps)


infixOps :: [(String, Expression () -> Expression () -> Expression ())]
infixOps =
    let
        infixOp str op =
            (str, InfixExpr () op)
    in
        [ infixOp "+"  OpAdd
        , infixOp "-"  OpSub
        , infixOp "*"  OpMul
        , infixOp "/"  OpDiv
        , infixOp "&&" OpLAnd
        , infixOp "||" OpLOr
        ]


specialOps :: [(String, Expression () -> Expression () -> Expression ())]
specialOps =
    [ (,) "^"  $ \a b -> obj ["Math","pow"] `call` [a,b]
    , (,) "|>" $ flip (<|)
    , (,) "==" $ \a b -> BuiltIn.eq a b
    , (,) "/=" $ \a b -> PrefixExpr () PrefixLNot (BuiltIn.eq a b)
    , (,) "<"  $ cmp OpLT 0
    , (,) ">"  $ cmp OpGT 0
    , (,) "<=" $ cmp OpLT 1
    , (,) ">=" $ cmp OpGT (-1)
    , (,) "//" $ \a b -> InfixExpr () OpBOr (InfixExpr () OpDiv a b) (IntLit () 0)
    ]


cmp :: InfixOp -> Int -> Expression () -> Expression () -> Expression ()
cmp op n a b =
    InfixExpr () op (BuiltIn.compare a b) (IntLit () n)


-- BINARY OPERATOR COLLECTORS

-- (h << g << f) becomes [f, g, h] which is the order you want for doing stuff
collectRightAssoc :: Var.Canonical -> Opt.Expr -> Opt.Expr -> [Opt.Expr]
collectRightAssoc desiredOp left right =
  collectRightAssocHelp desiredOp [left] right


collectRightAssocHelp :: Var.Canonical -> [Opt.Expr] -> Opt.Expr -> [Opt.Expr]
collectRightAssocHelp desiredOp exprList expr =
    case expr of
      A.A _ (Binop op left right) | op == desiredOp ->
          collectRightAssocHelp desiredOp (left : exprList) right

      _ ->
          expr : exprList


-- (f >> g >> h) becomes [f, g, h] which is the order you want for doing stuff
collectLeftAssoc :: Var.Canonical -> Opt.Expr -> Opt.Expr -> [Opt.Expr]
collectLeftAssoc desiredOp left right =
  collectLeftAssocHelp desiredOp [right] left


collectLeftAssocHelp :: Var.Canonical -> [Opt.Expr] -> Opt.Expr -> [Opt.Expr]
collectLeftAssocHelp desiredOp exprList expr =
    case expr of
      A.A _ (Binop op left right) | op == desiredOp ->
          collectLeftAssocHelp desiredOp (right : exprList) left

      _ ->
          expr : exprList

