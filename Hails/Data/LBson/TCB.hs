{-# LANGUAGE CPP #-}
#if __GLASGOW_HASKELL__ >= 704
{-# LANGUAGE Unsafe #-}
#endif
{- | This module exports an interface for LBSON (Labeled BSON) object.
   An LBSON object is either a BSON object (see 'Data.Bson') with the
   added support for labeled 'Value's. More specifically, a LBSON
   document is a list of 'Field's (which are 'Key'-'Value' pairs),
   where the 'Value' of a 'Field' can either be a standard
   'Data.Bson.Value' type or a 'Labeled' 'Value' type.
-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverlappingInstances #-}

--TODO: remove
#define DEBUG 1
--

module Hails.Data.LBson.TCB ( -- * UTF-8 String
                              module Data.UString
                              -- * Document
                            , Document, LabeledDocument
                            , look, lookup, valueAt, at, include, exclude, merge
                              -- * Field
                            , Field(..), (=:), (=?)
                            , Key
                              -- * Value
                            , Value(..), Val(..), cast, typed
                              -- * Policy labeled values
                            , PolicyLabeled(..), pu, pl
                              -- * Special Bson value types
                            , Binary(..)
                            , Function(..)
                            , UUID(..)
                            , MD5(..)
                            , UserDefined(..)
                            , Regex(..)
                            , Javascript(..)
                            , Symbol(..)
                            , MongoStamp(..)
                            , MinMaxKey(..)
                              -- ** ObjectId
                            , ObjectId(..)
                            , timestamp
                            , genObjectId
                            ) where


import Prelude hiding (lookup,)
import Data.UString (UString, u, unpack)
import qualified Data.Bson as Bson
import Data.Bson ( Binary(..)
                 , Function(..)
                 , UUID(..)
                 , MD5(..)
                 , UserDefined(..)
                 , Regex(..)
                 , Javascript(..)
                 , Symbol(..)
                 , MongoStamp(..)
                 , MinMaxKey(..)
                 , ObjectId(..)
                 , timestamp)

import LIO
import LIO.TCB (labelTCB, unlabelTCB, rtioTCB)
#if DEBUG
import LIO.TCB (showTCB)
#endif

import Data.Maybe (mapMaybe, maybeToList)
import Data.List (find, findIndex)
import Data.Typeable hiding (cast)

import Control.Monad.Identity (runIdentity)

--
-- Document related
--


-- | A 'Key', or attribute is a BSON label.
type Key = Bson.Label

-- | A LBSON document is a list of 'Field's
type Document l = [Field l]

-- | A labeled 'Document'
type LabeledDocument l = Labeled l (Document l)

-- | Value of field in document, or fail (Nothing) if field not found
look :: (Monad m, Label l) => Key -> Document l -> m (Value l)
look k doc = maybe notFound (return . value) (find ((k ==) . key) doc)
  where notFound = fail $ "expected " ++ show k

-- | Lookup value of field in document and cast to expected
-- type. Fail (Nothing) if field not found or value not of expected
-- type.
lookup :: (Val l v, Monad m, Label l) => Key -> Document l -> m v
lookup k doc = cast =<< look k doc


-- | Value of field in document. Error if missing.
valueAt :: Label l => Key -> [Field l] -> Value l
valueAt k = runIdentity . look k

-- | Typed value of field in document. Error if missing or wrong type.
at :: forall v l. (Val l v, Label l) => Key -> Document l -> v
at k doc = maybe err id (lookup k doc)
  where err = error $ "expected (" ++ show k ++ " :: "
                ++ show (typeOf (undefined :: v)) ++ ") in " ++ show doc

-- | Only include fields of document in key list
include :: Label l => [Key] -> Document l -> Document l
include keys doc = mapMaybe (\k -> find ((k ==) . key) doc) keys

-- | Exclude fields from document in key list
exclude :: Label l => [Key] -> Document l -> Document l
exclude keys doc = filter (\(k := _) -> notElem k keys) doc

-- | Merge documents with preference given to first one when both
-- have the same key. I.e. for every (k := v) in first argument,
-- if k exists in second argument then replace its value with v,
-- otherwise add (k := v) to second argument.
merge :: Label l => Document l -> Document l -> Document l
merge es doc' = foldl f doc' es where
	f doc (k := v) = case findIndex ((k ==) . key) doc of
		Nothing -> doc ++ [k := v]
		Just i -> let (x, _ : y) = splitAt i doc in x ++ [k := v] ++ y

--
-- Field related
--

infix 0 :=, =:, =?

-- | A @Field@ is a 'Key'-'Value' pair.
data Field l = (:=) { key :: !Key
                    , value :: Value l }
                    deriving (Eq, Typeable)

instance Label l => Show (Field l) where
  showsPrec d (k := v) = showParen (d > 0) $
    showString (' ' : unpack k) . showString ": " . showsPrec 1 v



-- | Field with given label and typed value
(=:) :: (Val l v, Label l) => Key -> v -> Field l
k =: v = k := val v

-- | If @Just@ value then return one field document, otherwise
-- return empty document
(=?) :: (Val l a, Label l) => Key -> Maybe a -> Document l
k =? ma = maybeToList (fmap (k =:) ma)

--
-- Value related
--

-- | A @Value@ is either a standard BSON value, a labeled value, or
-- a policy-labeled value.
data Value l = BsonVal Bson.Value
             -- ^ Unlabeled BSON value
             | LabeledVal (Labeled l Bson.Value)
             -- ^ Labeled (LBSON) value
             | PolicyLabeledVal (PolicyLabeled l Bson.Value)
             -- ^ Policy labeled (LBSON) value
             deriving (Typeable)

-- | Instance for @Show@, only showing unlabeled BSON values.
instance Label l => Show (Value l) where
  show (BsonVal v) = show v
#if DEBUG
  show (LabeledVal lv) = showTCB lv
  show (PolicyLabeledVal lv) = show lv
#else
  show _ = "{- HIDING DATA -} "
#endif

-- | Instance for @Eq@, only comparing unlabeled BSON values.
instance Label l => Eq (Value l) where
  (==) (BsonVal v1) (BsonVal v2) = v1 == v2
  (==) _ _ = False


-- | Haskell types of this class correspond to LBSON value types.
class (Typeable a, Show a, Eq a, Label l) => Val l a where
  val   :: a -> Value l
  cast' :: Value l -> Maybe a

-- | Every type that is an instance of BSON Val is an instance of
-- LBSON Val. This requires the use of @OverlappingInstances@
-- extension.
instance (Bson.Val a, Label l) => Val l a where
  val   = BsonVal . Bson.val
  cast' (BsonVal v) = Bson.cast' v
  cast' _           = Nothing
              
-- | Every type that is an instance of BSON Val is an instance of
-- LBSON Val.
instance (Label l) => Val l (Value l) where
  val   = id
  cast' = Just

-- | Convert between a labeled value and a labeled BSON value.
instance (Bson.Val a, Label l) => Val l (Labeled l a) where
  val lv = let l = labelOf lv
               v = unlabelTCB lv
           in LabeledVal $ labelTCB l (Bson.val v)
  cast' (LabeledVal lv) = let l = labelOf lv
                              v = unlabelTCB lv
                          in Bson.cast' v >>= return . labelTCB l
  cast' _ = Nothing

-- | Convert between a policy-labeled value and a labeled BSON value.
instance (Bson.Val a, Label l) => Val l (PolicyLabeled l a) where
  val (PU x) = PolicyLabeledVal . PU . Bson.val $ x
  val (PL lv) = let l = labelOf lv
                    v = unlabelTCB lv
                in PolicyLabeledVal . PL $ labelTCB l (Bson.val v)
  cast' (PolicyLabeledVal (PU v)) = Bson.cast' v >>= return . PU
  cast' (PolicyLabeledVal (PL lv)) = let l = labelOf lv
                                         v = unlabelTCB lv
                                     in Bson.cast' v >>=
                                        return . PL . labelTCB l
  cast' _ = Nothing


-- | Convert Value to expected type, or fail (Nothing) if not of that type
cast :: forall m l a. (Label l, Val l a, Monad m) => Value l -> m a
cast v = maybe notType return (cast' v)
  where notType = fail $ "expected " ++ show (typeOf (undefined :: a))
                                     ++ ": " ++ show v


-- | Convert Value to expected type. Error if not that type.
typed :: (Val l a, Label l) => Value l -> a
typed = runIdentity . cast

--
-- Misc.
--


-- | Necessary instance that just fails.
instance (Show a, Label l) => Show (Labeled l a) where
#if DEBUG
  show = showTCB 
#else
  show = error "Instance of show for Labeled not supported"
#endif

-- | Necessary instance that just fails.
instance Label l => Eq (Labeled l a) where
  (==)   = error "Instance of Eq for Labeled not supported"

-- | Generate fresh 'ObjectId'.
genObjectId :: LabelState l p s => LIO l p s ObjectId
genObjectId = rtioTCB $ Bson.genObjectId


--
-- Policy labeled values
--

-- | Simple sum type used to denote a policy-labeled type. A
-- @PolicyLabeled@ type can be either labeled (policy applied),
-- or unabled (policy not yet applied).
data PolicyLabeled l a = PU a             -- ^ Policy was not applied 
                       | PL (Labeled l a) -- ^ Policy applied
                       deriving (Typeable)

-- | Wrap an unlabeled value by 'PolicyLabeled'.
pu :: (Label l, Bson.Val a) => a -> PolicyLabeled l a
pu = PU

-- | Wrap an already-labeled value by 'PolicyLabeled'.
pl :: (Label l, Bson.Val a) => Labeled l a -> PolicyLabeled l a
pl = PL

-- | Necessary instance that just fails.
instance (Show a, Label l) => Show (PolicyLabeled l a) where
#if DEBUG
  show (PU x) = show x 
  show (PL x) = showTCB x 
#else
  show = error "Instance of show for PolicyLabeled not supported"
#endif

-- | Necessary instance that just fails.
instance Label l => Eq (PolicyLabeled l a) where
  (==) = error "Instance of show for PolicyLabeled not supported"