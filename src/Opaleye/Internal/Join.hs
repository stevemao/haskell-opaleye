{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE Arrows #-}

module Opaleye.Internal.Join where

import qualified Opaleye.Internal.HaskellDB.PrimQuery as HPQ
import qualified Opaleye.Internal.PackMap             as PM
import qualified Opaleye.Internal.Tag                 as T
import qualified Opaleye.Internal.Unpackspec          as U
import           Opaleye.Internal.Column (Field_(Column), FieldNullable)
import qualified Opaleye.Internal.QueryArr as Q
import qualified Opaleye.Internal.Operators as Op
import qualified Opaleye.Internal.PrimQuery as PQ
import qualified Opaleye.Internal.PGTypesExternal as T
import qualified Opaleye.Internal.Rebind as Rebind
import qualified Opaleye.SqlTypes as T
import qualified Opaleye.Field as C
import           Opaleye.Field   (Field)
import           Opaleye.Internal.MaybeFields (MaybeFields(MaybeFields),
                                               mfPresent, mfFields)
import qualified Opaleye.Select  as S

import qualified Control.Applicative as A
import qualified Control.Arrow

import           Data.Profunctor (Profunctor, dimap)
import qualified Data.Profunctor.Product as PP
import qualified Data.Profunctor.Product.Default as D

newtype NullMaker a b = NullMaker (a -> b)

toNullable :: NullMaker a b -> a -> b
toNullable (NullMaker f) = f

instance D.Default NullMaker (Field a) (FieldNullable a) where
  def = NullMaker C.toNullable

instance D.Default NullMaker (FieldNullable a) (FieldNullable a) where
  def = NullMaker id

joinExplicit :: U.Unpackspec columnsA columnsA
             -> U.Unpackspec columnsB columnsB
             -> (columnsA -> returnedColumnsA)
             -> (columnsB -> returnedColumnsB)
             -> PQ.JoinType
             -> Q.Query columnsA -> Q.Query columnsB
             -> ((columnsA, columnsB) -> Field T.PGBool)
             -> Q.Query (returnedColumnsA, returnedColumnsB)
joinExplicit uA uB returnColumnsA returnColumnsB joinType
             qA qB cond = Q.productQueryArr $ do
  (columnsA, primQueryA) <- Q.runSimpleSelect qA
  (columnsB, primQueryB) <- Q.runSimpleSelect qB

  endTag <- T.fresh

  let (newColumnsA, ljPEsA) =
            PM.run (U.runUnpackspec uA (extractLeftJoinFields 1 endTag) columnsA)
      (newColumnsB, ljPEsB) =
            PM.run (U.runUnpackspec uB (extractLeftJoinFields 2 endTag) columnsB)

      nullableColumnsA = returnColumnsA newColumnsA
      nullableColumnsB = returnColumnsB newColumnsB

      Column cond' = cond (columnsA, columnsB)
      primQueryR = PQ.Join joinType cond'
                               (PQ.NonLateral, (PQ.Rebind True ljPEsA primQueryA))
                               (PQ.NonLateral, (PQ.Rebind True ljPEsB primQueryB))

  pure ((nullableColumnsA, nullableColumnsB), primQueryR)


leftJoinAExplicit :: U.Unpackspec a a
                  -> NullMaker a nullableA
                  -> Q.Query a
                  -> Q.QueryArr (a -> Field T.PGBool) nullableA
leftJoinAExplicit uA nullmaker rq =
  Q.leftJoinQueryArr' $ do
    (newColumnsR, right) <- Q.runSimpleSelect $ proc () -> do
          a <- rq -< ()
          Rebind.rebindExplicit uA -< a
    pure $ \p ->
      let renamedNullable = toNullable nullmaker newColumnsR
          Column cond = p newColumnsR
      in (renamedNullable, cond, right)

optionalRestrict :: D.Default U.Unpackspec a a
                 => S.Select a
                 -> S.SelectArr (a -> Field T.SqlBool) (MaybeFields a)
optionalRestrict = optionalRestrictExplicit D.def

optionalRestrictExplicit :: U.Unpackspec a a
                         -> S.Select a
                         -> S.SelectArr (a -> Field T.SqlBool) (MaybeFields a)
optionalRestrictExplicit uA q =
  dimap (. snd) (\(nonNullIfPresent, rest) ->
      let present = Op.not (C.isNull (C.unsafeCoerceField nonNullIfPresent))
      in MaybeFields { mfPresent = present
                     , mfFields  = rest
                     }) $
  leftJoinAExplicit (PP.p2 (U.unpackspecField, uA))
                    (Opaleye.Internal.Join.NullMaker id)
                    (fmap (\x -> (T.sqlBool True, x)) q)

-- | An example to demonstrate how the functionality of @LEFT JOIN@
-- can be recovered using 'optionalRestrict'.
leftJoinInTermsOfOptionalRestrict :: D.Default U.Unpackspec fieldsR fieldsR
                                  => S.Select fieldsL
                                  -> S.Select fieldsR
                                  -> ((fieldsL, fieldsR) -> Field T.SqlBool)
                                  -> S.Select (fieldsL, MaybeFields fieldsR)
leftJoinInTermsOfOptionalRestrict qL qR cond = proc () -> do
  fieldsL <- qL -< ()
  maybeFieldsR <- optionalRestrict qR -< curry cond fieldsL
  Control.Arrow.returnA -< (fieldsL, maybeFieldsR)

extractLeftJoinFields :: Int
                      -> T.Tag
                      -> HPQ.PrimExpr
                      -> PM.PM [(HPQ.Symbol, HPQ.PrimExpr)] HPQ.PrimExpr
extractLeftJoinFields n = PM.extractAttr ("result" ++ show n ++ "_")

-- { Boilerplate instances

instance Functor (NullMaker a) where
  fmap f (NullMaker g) = NullMaker (fmap f g)

instance A.Applicative (NullMaker a) where
  pure = NullMaker . A.pure
  NullMaker f <*> NullMaker x = NullMaker (f A.<*> x)

instance Profunctor NullMaker where
  dimap f g (NullMaker h) = NullMaker (dimap f g h)

instance PP.ProductProfunctor NullMaker where
  purePP = pure
  (****) = (<*>)
