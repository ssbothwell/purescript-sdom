module StaticDOM
  ( StaticDOM
  , SDFX
  , Attr(..)
  , element
  , element_
  , ArrayChannel(..)
  , array
  , text
  , runStaticDOM
  ) where

import Prelude

import Control.Alternative (empty, (<|>))
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Ref (REF, newRef, readRef, writeRef)
import Control.Monad.Rec.Class (Step(..), tailRecM)
import DOM (DOM)
import DOM.Event.Event as Event
import DOM.Event.EventTarget (addEventListener, eventListener)
import DOM.HTML (window)
import DOM.HTML.HTMLInputElement (setValue)
import DOM.HTML.Types (htmlDocumentToDocument)
import DOM.HTML.Window (document)
import DOM.Node.Document (createDocumentFragment, createElement, createTextNode)
import DOM.Node.Element (removeAttribute, setAttribute)
import DOM.Node.Node (appendChild, lastChild, removeChild, setTextContent)
import DOM.Node.Types (Element, Node, documentFragmentToNode, elementToEventTarget, elementToNode, textToNode)
import Data.Array (length, modifyAt, unsafeIndex, (!!), (..))
import Data.Either (Either(..), either)
import Data.Filterable (filterMap)
import Data.Foldable (for_, oneOf)
import Data.FoldableWithIndex (traverseWithIndex_)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Newtype (wrap)
import Data.Profunctor (class Profunctor, dimap)
import Data.Profunctor.Strong (class Strong, first, second)
import Data.StrMap as StrMap
import Data.Traversable (traverse)
import Data.TraversableWithIndex (traverseWithIndex)
import Data.Tuple (Tuple(..), fst, snd)
import FRP (FRP)
import FRP.Event (Event, create, subscribe)
import Partial.Unsafe (unsafePartial)
import Unsafe.Coerce (unsafeCoerce)

type SDFX eff = (dom :: DOM, frp :: FRP | eff)

newtype StaticDOM eff ch i o = StaticDOM
  (Node
  -> i
  -> Event { old :: i, new :: i }
  -> Eff eff (Event (Either ch (i -> o))))

instance functorStaticDOM :: Functor (StaticDOM eff ch i) where
  map f (StaticDOM sd) = StaticDOM \n a e ->
    map (map (map f)) <$> sd n a e

instance profunctorStaticDOM :: Profunctor (StaticDOM eff ch) where
  dimap f g (StaticDOM sd) = StaticDOM \n a e ->
    map (map (dimap f g)) <$> sd n (f a) (map (\{old, new} -> { old: f old, new: f new }) e)

instance strongStaticDOM :: Strong (StaticDOM eff ch) where
  first (StaticDOM sd) = StaticDOM \n (Tuple a _) e ->
    map (map first) <$> sd n a (map (\{ old, new } -> { old: fst old, new: fst new }) e)
  second (StaticDOM sd) = StaticDOM \n (Tuple _ b) e ->
    map (map second) <$> sd n b (map (\{ old, new } -> { old: snd old, new: snd new }) e)

unStaticDOM
  :: forall eff ch i o
   . StaticDOM eff ch i o
  -> Node
  -> i
  -> Event { old :: i, new :: i }
  -> Eff eff (Event (Either ch (i -> o)))
unStaticDOM (StaticDOM f) = f

text :: forall eff ch i o. (i -> String) -> StaticDOM (SDFX eff) ch i o
text f = StaticDOM \n model e -> do
  doc <- window >>= document
  tn <- createTextNode (f model) (htmlDocumentToDocument doc)
  _ <- appendChild (textToNode tn) n
  _ <- e `subscribe` \{old, new} -> do
    let oldValue = f old
        newValue = f new
    when (oldValue /= newValue) $
      setTextContent newValue (textToNode tn)
  pure empty

element_
  :: forall eff ch i o
   . String
  -> Array (StaticDOM (SDFX eff) ch i o)
  -> StaticDOM (SDFX eff) ch i o
element_ el = element el StrMap.empty StrMap.empty

data Attr
  = StringAttr String
  | BooleanAttr Boolean

derive instance eqAttr :: Eq Attr

element
  :: forall eff ch i o
   . String
  -> StrMap.StrMap (i -> Attr)
  -> StrMap.StrMap (Event.Event -> Either ch (i -> o))
  -> Array (StaticDOM (SDFX eff) ch i o)
  -> StaticDOM (SDFX eff) ch i o
element el attrs handlers children = StaticDOM \n model updates -> do
  doc <- window >>= document
  e <- createElement el (htmlDocumentToDocument doc)
  _ <- appendChild (elementToNode e) n
  let setAttr
        :: String
        -> (i -> Attr)
        -> Eff (SDFX eff) Unit
      setAttr attrName f = do
        let go = case _ of
                   StringAttr s ->
                     case attrName of
                       "value" -> setValue s (unsafeCoerce e)
                       _ -> setAttribute attrName s e
                   BooleanAttr true -> setAttribute attrName attrName e
                   BooleanAttr false -> removeAttribute attrName e
        go (f model)
        _ <- updates `subscribe` \{old, new} -> do
              let oldValue = f old
                  newValue = f new
              when (oldValue /= newValue) $
                go newValue
        pure unit

      setHandler
        :: String
        -> (Event.Event -> Either ch (i -> o))
        -> Eff (SDFX eff) (Event (Either ch (i -> o)))
      setHandler evtName f = do
        {event, push} <- create
        addEventListener (wrap evtName) (eventListener (push <<< f)) false (elementToEventTarget e)
        pure event
  traverseWithIndex_ setAttr attrs
  evts <- traverseWithIndex setHandler handlers
  childrenEvts <- traverse (\child -> unStaticDOM child (elementToNode e) model updates) children
  pure (oneOf evts <|> oneOf childrenEvts)

removeLastNChildren :: forall eff. Int -> Node -> Eff (dom :: DOM | eff) Unit
removeLastNChildren m n = tailRecM loop m where
  loop toRemove
    | toRemove <= 0 = pure (Done unit)
    | otherwise = do
    child <- lastChild n
    case child of
      Nothing -> pure (Done unit)
      Just child_ -> do _ <- removeChild child_ n
                        pure (Loop (toRemove - 1))

data ArrayChannel i channel
  = Parent channel
  | Here (Int -> Array i -> Array i)

array
  :: forall eff ch i
   . String
  -> StaticDOM (SDFX eff) (ArrayChannel i ch) i i
  -> StaticDOM (SDFX eff) ch (Array i) (Array i)
array el sd = StaticDOM \n models updates -> do
  doc <- window >>= document
  e <- createElement el (htmlDocumentToDocument doc)
  _ <- appendChild (elementToNode e) n
  {event, push} <- create
  let setup :: Array i -> Array i -> Eff (SDFX eff) Unit
      setup old_ new_
        | length new_ > length old_ = do
          for_ (length old_ .. (length new_ - 1)) \idx -> do
            fragment <- createDocumentFragment (htmlDocumentToDocument doc)
            let frag = documentFragmentToNode fragment
                here xs = unsafePartial (xs `unsafeIndex` idx)
            childEvts <- unStaticDOM sd frag (here new_) (filterMap (\{old, new} -> { old: _, new: _ } <$> (old !! idx) <*> (new !! idx)) updates)
            _ <- childEvts `subscribe` \ev ->
              case ev of
                Left (Parent other) -> push (Left other)
                Left (Here fi) -> push (Right (fi idx))
                Right f -> push (Right (fromMaybe <*> modifyAt idx f))
            _ <- appendChild frag (elementToNode e)
            pure unit
        | length new_ < length old_ = do
          removeLastNChildren (length old_ - length new_) (elementToNode e)
        | otherwise = pure unit -- nothing to do
  setup [] models
  _ <- updates `subscribe` \{old, new} -> setup old new
  pure event

runStaticDOM
  :: forall model eff
   . Element
  -> model
  -> StaticDOM (SDFX (ref :: REF | eff)) Void model model
  -> Eff (SDFX (ref :: REF | eff)) Unit
runStaticDOM root model v = do
  modelRef <- newRef model
  document <- window >>= document
  { event, push } <- create
  fragment <- createDocumentFragment (htmlDocumentToDocument document)
  let n = documentFragmentToNode fragment
  updates <- unStaticDOM v n model event
  _ <- updates `subscribe` \e -> do
    oldModel <- readRef modelRef
    let f = either absurd id e
        newModel = f oldModel
    _ <- writeRef modelRef newModel
    push { old: oldModel, new: newModel }
  _ <- appendChild n (elementToNode root)
  pure unit
