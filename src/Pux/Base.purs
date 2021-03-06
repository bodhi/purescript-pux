module Pux.Base
  ( App
  , Config
  , Update
  , EffModel
  , CoreEffects
  , noEffects
  , onlyEffects
  , fromSimple
  , mapState
  , mapEffects
  , start
  , start'
  , element
  , render
  , Renderer
  ) where

import Control.Monad.Aff (Aff, launchAff, later)
import Control.Monad.Aff.Unsafe (unsafeCoerceAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Exception (EXCEPTION)
import Data.Foldable (foldl, sequence_)
import Data.Function.Uncurried (Fn3, runFn3)
import Data.List (List(Nil), singleton, (:), reverse, fromFoldable)
import Data.Maybe (fromJust)
import Partial.Unsafe (unsafePartial)
import Prelude (Unit, ($), (<<<), map, pure)
import Prelude as Prelude
import Pux.Html.Elements (Attribute)
import Signal (Signal, (~>), mergeMany, foldp, runSignal)
import Signal.Channel (CHANNEL, Channel, channel, subscribe, send)

type Renderer target a eff = Fn3 (a -> Eff eff Unit) (a -> a) (target a) (target a)

-- | Start an application. The resulting html signal is fed into `renderToDOM`.
-- |
-- | ```purescript
-- | main = do
-- |   app <- start
-- |     { update: update
-- |     , view: view
-- |     , initialState: initialState
-- |     , inputs: [] }
-- |
-- |   renderToDOM "#app" app.html
-- | ```
start' :: forall state action eff target.
         Renderer target action (CoreEffects eff) ->
         Config target state action eff ->
         Eff (CoreEffects eff) (App target state action)
start' render' config = do
  actionChannel <- channel Nil
  let actionSignal = subscribe actionChannel
      input = unsafePartial $ fromJust $ mergeMany $
        reverse (actionSignal : map (map singleton) (fromFoldable $ config.inputs))
      foldState effModel action = config.update action effModel.state
      foldActions actions effModel =
        foldl foldState (noEffects effModel.state) actions
      effModelSignal =
        foldp foldActions (noEffects config.initialState) input
      stateSignal = effModelSignal ~> _.state
      htmlSignal = stateSignal ~> \state ->
        (runFn3 render') (send actionChannel <<< singleton) (\a -> a) (config.view state)
      mapAffect affect = launchAff $ unsafeCoerceAff do
        action <- later affect
        liftEff $ send actionChannel (singleton action)
      effectsSignal = effModelSignal ~> map mapAffect <<< _.effects
  runSignal $ effectsSignal ~> sequence_
  pure $ { html: htmlSignal, state: stateSignal, actionChannel: actionChannel }
  where bind = Prelude.bind

start :: forall state action eff target.
         Config target state action eff ->
         Eff (CoreEffects eff) (App target state action)
start = start' render

foreign import render :: forall a eff target. Renderer target a eff

-- | The configuration of an app consists of update and view functions along
-- | with an initial state.
-- |
-- | The `update` and `view` functions describe how to step the state and view
-- | the state.
-- |
-- | The `inputs` array is for any external signals you might need. These will
-- | be merged into the app's input signal.
type Config target state action eff =
  { update :: Update state action eff
  , view :: state -> target action
  , initialState :: state
  , inputs :: Array (Signal action)
  }

-- | The set of effects every Pux app needs to allow through when using `start`.
-- | Extend this type with your own app's effects, for example:
-- |
-- | ```purescript
-- | type AppEffects = (console :: CONSOLE, dom :: DOM)
-- |
-- | main :: State -> Eff (CoreEffects AppEffects) (App State Action)
-- | main state = do
-- |   -- ...
-- | ```
type CoreEffects eff = (channel :: CHANNEL, err :: EXCEPTION | eff)

-- | An `App` consists of three signals:
-- |
-- | * `html` – A signal of `Html` representing the current view of your
-- |   app. This should be fed into `renderToDOM`.
-- |
-- | * `state` – A signal representing the application's current state.
type App target state action =
  { html :: Signal (target action)
  , state :: Signal state
  , actionChannel :: Channel (List action)
  }

-- | Synonym for an update function that returns state and an array of
-- | asynchronous effects that return an action.
type Update state action eff = action -> state -> EffModel state action eff

-- | `EffModel` is a container for state and a collection of asynchronous
-- | effects which return an action.
type EffModel state action eff =
  { state :: state
  , effects :: Array (Aff (CoreEffects eff) action) }

-- | Create an `Update` function from a simple step function.
fromSimple :: forall s a eff. (a -> s -> s) -> Update s a eff
fromSimple update = \action state -> noEffects $ update action state

-- | Create an `EffModel` with no effects from a given state.
noEffects :: forall state action eff. state -> EffModel state action eff
noEffects state = { state: state, effects: [] }

onlyEffects :: forall state action eff.
               state -> Array (Aff (CoreEffects eff) action) -> EffModel state action eff
onlyEffects state effects = { state: state, effects: effects }

-- | Map over the state of an `EffModel`.
mapState :: forall sa sb a e. (sa -> sb) -> EffModel sa a e -> EffModel sb a e
mapState a2b effmodel =
  { state: a2b effmodel.state, effects: effmodel.effects }

-- | Map over the effectful actions of an `EffModel`.
mapEffects :: forall s a b e. (a -> b) -> EffModel s a e -> EffModel s b e
mapEffects action effmodel =
  { state: effmodel.state, effects: map (map action) effmodel.effects }

foreign import element :: forall a target.
                          Fn3 String (Array (Attribute a)) (Array (target a)) (target a)
