{-# OPTIONS_HADDOCK not-home #-}

module Opaleye.Internal.Binary where

import           Opaleye.Internal.Column (Field_(Column), unColumn)
import qualified Opaleye.Internal.Tag as T
import qualified Opaleye.Internal.PackMap as PM
import qualified Opaleye.Internal.QueryArr as Q
import qualified Opaleye.Internal.PrimQuery as PQ

import qualified Opaleye.Internal.HaskellDB.PrimQuery as HPQ

import           Data.Profunctor (Profunctor, dimap)
import           Data.Profunctor.Product (ProductProfunctor)
import qualified Data.Profunctor.Product as PP
import           Data.Profunctor.Product.Default (Default, def)

import           Control.Arrow ((***))

extractBinaryFields :: T.Tag -> (HPQ.PrimExpr, HPQ.PrimExpr)
                    -> PM.PM [(HPQ.Symbol, (HPQ.PrimExpr, HPQ.PrimExpr))]
                             HPQ.PrimExpr
extractBinaryFields = PM.extractAttr "binary"

newtype Binaryspec fields fields' =
  Binaryspec (PM.PackMap (HPQ.PrimExpr, HPQ.PrimExpr) HPQ.PrimExpr
                         (fields, fields) fields')

runBinaryspec :: Applicative f => Binaryspec columns columns'
                 -> ((HPQ.PrimExpr, HPQ.PrimExpr) -> f HPQ.PrimExpr)
                 -> (columns, columns) -> f columns'
runBinaryspec (Binaryspec b) = PM.traversePM b

binaryspecColumn :: Binaryspec (Field_ n a) (Field_ n a)
binaryspecColumn = dimap unColumn Column (Binaryspec (PM.PackMap id))

sameTypeBinOpHelper :: PQ.BinOp -> Binaryspec columns columns'
                    -> Q.Query columns -> Q.Query columns -> Q.Query columns'
sameTypeBinOpHelper binop binaryspec q1 q2 = Q.productQueryArr $ do
  (columns1, primQuery1) <- Q.runSimpleSelect q1
  (columns2, primQuery2) <- Q.runSimpleSelect q2

  endTag <- T.fresh

  let (newColumns, pes) =
            PM.run (runBinaryspec binaryspec (extractBinaryFields endTag)
                                    (columns1, columns2))

      newPrimQuery = PQ.Binary binop
            ( PQ.Rebind False (map (fmap fst) pes) primQuery1
            , PQ.Rebind False (map (fmap snd) pes) primQuery2
            )

  pure (newColumns, newPrimQuery)


instance Default Binaryspec (Field_ n a) (Field_ n a) where
  def = binaryspecColumn

-- {

-- Boilerplate instance definitions.  Theoretically, these are derivable.

instance Functor (Binaryspec a) where
  fmap f (Binaryspec g) = Binaryspec (fmap f g)

instance Applicative (Binaryspec a) where
  pure = Binaryspec . pure
  Binaryspec f <*> Binaryspec x = Binaryspec (f <*> x)

instance Profunctor Binaryspec where
  dimap f g (Binaryspec b) = Binaryspec (dimap (f *** f) g b)

instance ProductProfunctor Binaryspec where
  purePP = pure
  (****) = (<*>)

-- }
