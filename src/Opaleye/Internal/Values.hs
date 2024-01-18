{-# LANGUAGE Arrows #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}

module Opaleye.Internal.Values where

import           Opaleye.Internal.Column (Field_(Column))
import qualified Opaleye.Internal.Column as C
import qualified Opaleye.Column as OC
import qualified Opaleye.Internal.Tag as T
import qualified Opaleye.Internal.Operators as O
import qualified Opaleye.Internal.PrimQuery as PQ
import qualified Opaleye.Internal.PackMap as PM
import qualified Opaleye.Internal.QueryArr as Q
import qualified Opaleye.Internal.HaskellDB.PrimQuery as HPQ
import qualified Opaleye.Internal.PGTypes
import qualified Opaleye.SqlTypes

import           Control.Arrow (returnA)
import qualified Control.Monad.Trans.State.Strict as State
import qualified Data.List.NonEmpty as NEL
import           Data.Profunctor (Profunctor, dimap, rmap, lmap)
import           Data.Profunctor.Product (ProductProfunctor)
import qualified Data.Profunctor.Product as PP
import           Data.Profunctor.Product.Default (Default, def)

import           Control.Applicative (liftA2)

nonEmptyValues :: Rowspec columns columns'
               -> NEL.NonEmpty columns
               -> Q.Select columns'
nonEmptyValues rowspec rows =
  let nerowspec' = case rowspec of
        NonEmptyRows nerowspec -> nerowspec
        EmptyRows fields ->
          dimap (const zero) (const fields) nonEmptyRowspecField
          where zero = 0 :: C.Field Opaleye.SqlTypes.SqlInt4
  in nonEmptyRows nerowspec' rows

nonEmptyRows :: NonEmptyRowspec fields fields'
             -> NEL.NonEmpty fields
             -> Q.Select fields'
nonEmptyRows (NonEmptyRowspec runRow fields) rows =
  Q.productQueryArr $ do
    (valuesPEs, newColumns) <- fields
    pure (newColumns, PQ.Values (NEL.toList valuesPEs) (fmap (NEL.toList . runRow) rows))

emptySelectExplicit :: Nullspec columns a -> Q.Select a
emptySelectExplicit nullspec = proc () -> do
  O.restrict -< Opaleye.SqlTypes.sqlBool False
  returnA -< nullFields nullspec

data NonEmptyRowspec fields fields' =
  NonEmptyRowspec (fields -> NEL.NonEmpty HPQ.PrimExpr)
                  (State.State T.Tag (NEL.NonEmpty HPQ.Symbol, fields'))

-- Some overlap here with extractAttrPE
nonEmptyRowspecField :: NonEmptyRowspec (Field_ n a) (Field_ n a)
nonEmptyRowspecField = dimap C.unColumn C.Column $ NonEmptyRowspec pure s
  where s = do
          t <- T.fresh
          let symbol = HPQ.Symbol "values" t
          pure (pure symbol, HPQ.AttrExpr symbol)

rowspecField :: Rowspec (Field_ n a) (Field_ n a)
rowspecField = NonEmptyRows nonEmptyRowspecField

data Rowspec fields fields' =
    NonEmptyRows (NonEmptyRowspec fields fields')
  | EmptyRows fields'

data Valuesspec fields fields' =
  ValuesspecSafe (Nullspec fields fields')
                 (Rowspec fields fields')

valuesspecField :: Opaleye.SqlTypes.IsSqlType a
                => Valuesspec (Field_ n a) (Field_ n a)
valuesspecField = def_
    where def_ = valuesspecFieldType (Opaleye.Internal.PGTypes.showSqlType sqlType)
          sqlType = columnProxy def_
          columnProxy :: f (Field_ n sqlType) -> Maybe sqlType
          columnProxy _ = Nothing

-- For rel8
valuesspecFieldType :: String -> Valuesspec (Field_ n a) (Field_ n a)
valuesspecFieldType sqlType =
  ValuesspecSafe (nullspecFieldType sqlType) rowspecField

instance forall a n. Opaleye.Internal.PGTypes.IsSqlType a
  => Default Valuesspec (Field_ n a) (Field_ n a) where
  def = ValuesspecSafe nullspecField rowspecField

newtype Nullspec fields fields' = Nullspec fields'

nullspecField :: forall a n sqlType.
                 Opaleye.SqlTypes.IsSqlType sqlType
              => Nullspec a (Field_ n sqlType)
nullspecField = nullspecFieldType ty
  where ty = Opaleye.Internal.PGTypes.showSqlType (Nothing :: Maybe sqlType)

nullspecFieldType :: String
                  -> Nullspec a (Field_ n sqlType)
nullspecFieldType sqlType =
  (Nullspec
  . C.unsafeCast sqlType
  . C.unsafeCoerceColumn)
  OC.null

nullspecList :: Nullspec a [b]
nullspecList = pure []

nullspecEitherLeft :: Nullspec a b
                   -> Nullspec a (Either b b')
nullspecEitherLeft = fmap Left

nullspecEitherRight :: Nullspec a b'
                    -> Nullspec a (Either b b')
nullspecEitherRight = fmap Right

instance Opaleye.SqlTypes.IsSqlType b
  => Default Nullspec a (Field_ n b) where
  def = nullspecField

-- | All fields @NULL@, even though technically the type may forbid
-- that!  Used to create such fields when we know we will never look
-- at them expecting to find something non-NULL.
nullFields :: Nullspec a fields -> fields
nullFields (Nullspec v) = v

-- {

-- Boilerplate instance definitions.  Theoretically, these are derivable.

instance Functor (ValuesspecUnsafe a) where
  fmap f (Valuesspec g) = Valuesspec (fmap f g)

instance Applicative (ValuesspecUnsafe a) where
  pure = Valuesspec . pure
  Valuesspec f <*> Valuesspec x = Valuesspec (f <*> x)

instance Profunctor ValuesspecUnsafe where
  dimap _ g (Valuesspec q) = Valuesspec (rmap g q)

instance ProductProfunctor ValuesspecUnsafe where
  purePP = pure
  (****) = (<*>)

instance Functor (Valuesspec a) where
  fmap f (ValuesspecSafe g h) = ValuesspecSafe (fmap f g) (fmap f h)

instance Applicative (Valuesspec a) where
  pure a = ValuesspecSafe (pure a) (pure a)
  ValuesspecSafe f f' <*> ValuesspecSafe x x' =
    ValuesspecSafe (f <*> x) (f' <*> x')

instance Profunctor Valuesspec where
  dimap f g (ValuesspecSafe q q') = ValuesspecSafe (dimap f g q) (dimap f g q')

instance ProductProfunctor Valuesspec where
  purePP = pure
  (****) = (<*>)

instance Functor (Nullspec a) where
  fmap f (Nullspec g) = Nullspec (f g)

instance Applicative (Nullspec a) where
  pure = Nullspec
  Nullspec f <*> Nullspec x = Nullspec (f x)

instance Profunctor Nullspec where
  dimap _ g (Nullspec q) = Nullspec (g q)

instance ProductProfunctor Nullspec where
  purePP = pure
  (****) = (<*>)

instance Functor (NonEmptyRowspec a) where
  fmap = rmap

instance Profunctor NonEmptyRowspec where
  dimap f g (NonEmptyRowspec a b) =
    NonEmptyRowspec (lmap f a) ((fmap . fmap) g b)

instance Functor (Rowspec a) where
  fmap = rmap

instance Applicative (Rowspec a) where
  pure x = EmptyRows x
  r1 <*> r2 = case (r1, r2) of
    (EmptyRows f, EmptyRows x) -> EmptyRows (f x)
    (EmptyRows f, NonEmptyRows (NonEmptyRowspec x1 x2)) ->
      NonEmptyRows (NonEmptyRowspec x1 ((fmap . fmap) f x2))
    (NonEmptyRows (NonEmptyRowspec f1 f2), EmptyRows x) ->
     NonEmptyRows (NonEmptyRowspec f1 ((fmap . fmap) ($ x) f2))
    (NonEmptyRows (NonEmptyRowspec f1 f2),
     NonEmptyRows (NonEmptyRowspec x1 x2)) ->
      NonEmptyRows (NonEmptyRowspec
            (f1 <> x1)
            ((liftA2 . liftF2) ($) f2 x2))

    where -- Instead of depending on Apply
          -- https://www.stackage.org/haddock/lts-19.16/semigroupoids-5.3.7/Data-Functor-Apply.html#v:liftF2
          liftF2 :: Semigroup m
                 => (a' -> b -> c) -> (m, a') -> (m, b) -> (m, c)
          liftF2 f (ys1, x1) (ys2, x2) = (ys1 <> ys2, f x1 x2)

instance Profunctor Rowspec where
  dimap f g = \case
    EmptyRows x -> EmptyRows (g x)
    NonEmptyRows x -> NonEmptyRows (dimap f g x)

instance ProductProfunctor Rowspec where
  purePP = pure
  (****) = (<*>)

-- }

newtype ValuesspecUnsafe columns columns' =
  Valuesspec (PM.PackMap () HPQ.PrimExpr () columns')

instance Default ValuesspecUnsafe (Field_ n a) (Field_ n a) where
  def = Valuesspec (PM.iso id Column)
