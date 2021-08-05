{-
Welcome to a Spago project!
You can edit this file as you like.
-}
{ name = "sdom"
, dependencies =
  [ "arrays"
  , "bifunctors"
  , "console"
  , "control"
  , "datetime"
  , "drawing"
  , "effect"
  , "either"
  , "filterable"
  , "foldable-traversable"
  , "js-timers"
  , "lists"
  , "maybe"
  , "newtype"
  , "now"
  , "partial"
  , "prelude"
  , "profunctor"
  , "profunctor-lenses"
  , "psci-support"
  , "refs"
  , "tailrec"
  , "tuples"
  , "unsafe-coerce"
  , "unsafe-reference"
  , "web-dom"
  , "web-events"
  , "web-html"
  ]
, packages = ./packages.dhall
, sources = [ "src/**/*.purs", "test/**/*.purs" ]
}
