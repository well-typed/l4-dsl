module Genre.Insurance.Policy2020 where

import Genre.Insurance.Common

type SumAssured = Int

-- * The benefits are organized into plans.
-- | Some plans have variants A through F.
-- They have different Sum Assured amounts based on the plan.
data BenefitsAF = BAF { pa :: SumAssured
                      , pb :: SumAssured
                      , pc :: SumAssured
                      , pd :: SumAssured
                      , pe :: SumAssured
                      , pf :: SumAssured
                      , pmodaf :: [Modifier Scenario] } deriving (Eq, Show)

-- | One plan has variants 1 through 4, with different Sum Assureds accordingly.
data Benefits14 = B14 { p1 :: SumAssured
                      , p2 :: SumAssured
                      , p3 :: SumAssured
                      , p4 :: SumAssured
                      , pmod14 :: [Modifier Scenario] } deriving (Eq, Show)
  
-- | A policy offering, or a policy template, bundles a collection of
-- benefits. Some are optional, some are mandatory, but the
-- optionality is not reflected here because everything is on offer.
-- The choice of opt-in or opt-out is recorded in `PolicyInstance`
-- below.
data PolicyTemplate = PolicyTemplate
  { ptNQQ :: BenefitsAF
  , ptZE  :: BenefitsAF
  , ptGPZ :: BenefitsAF
  , ptEN  :: BEN
  , ptSP  :: BSP
  }
policyTemplate2020 :: PolicyTemplate
policyTemplate2020 = PolicyTemplate
  { ptNQQ = BAF 1000000 2000000 3000000 5000000 7500000 10000000 []
  , ptZE  = BAF   20000   25000   30000   40000   50000    60000 []
  , ptGPZ = BAF    5000    5000   10000   10000   12500    15000 []
  , ptEN  = BEN { pqnuv  = BAF    500    1000    1500    2500    3500    4500 []
                , pqnvph = BAF    500    1000    1500    2500    3500    4500 []
                , pzn    = BAF  10000   10000   10000   20000   20000   25000 []
                , ptjg   = BAF    500     500     500     500     500     500 []
                , psfs   = BAF 300000  300000  600000 1000000 1500000 2000000 []
                }
  , ptSP  = BSP { spsoq = B14  250000  500000  750000 1000000 []
                , spzn  = B14    2500    5000    7500   10000 []
                , spusr = B14   25000   50000   75000  100000 []
                , speo  = B14    2500    5000    7500   10000 []
                }
  }


-- | One of the optional benefits, the "EN" benefit, has sub-benefits also organized by plan A--F.
data BEN = BEN { pqnuv  :: BenefitsAF
               , pqnvph :: BenefitsAF
               , pzn    :: BenefitsAF
               , ptjg   :: BenefitsAF
               , psfs   :: BenefitsAF } deriving (Eq, Show)

-- | One of the benefits has sub-benefit variants 1 through 4.
data BSP = BSP { spsoq :: Benefits14
               , spzn  :: Benefits14
               , spusr :: Benefits14
               , speo  :: Benefits14 } deriving (Eq, Show)

-- * Now we begin to get into the operationalizations.

-- | A concrete policy instance has narrowed from A--F and 1--4 to a
-- single sum assured for each one of the benefits and sub-benefits.
-- The two optional benefits are recorded as Maybes.
data PolicyInstance = PolicyInstance
  { piNQQ :: SumAssured
  , piZE  :: SumAssured
  , piGPZ :: SumAssured
  , piEN  :: Maybe PIBEN
  , piSP  :: Maybe PISP } deriving (Eq, Show)

-- | A concrete policy instance of the EN benefit
data PIBEN = PIBEN { piqnuv  :: SumAssured
                   , piqnvph :: SumAssured
                   , pizn    :: SumAssured
                   , pitjg   :: SumAssured
                   , pisfs   :: SumAssured } deriving (Eq, Show)

-- | A concrete policy instance of the SP benefit
data PISP = PISP { pispsoq :: SumAssured
                 , pispzn  :: SumAssured
                 , pispusr :: SumAssured
                 , pispeo  :: SumAssured } deriving (Eq, Show)

-- | The constructor function requires that the caller choose one of the plans based on pa--pf and p1--p4.
mkPolicy :: PolicyTemplate
         -> (BenefitsAF -> SumAssured)
         -> Maybe ({- follows above -}) -- does it opt for the supplemental BEN benefit?
         -> Maybe (Benefits14 -> SumAssured)   -- does it opt for the supplemental SP  benefit?
         -> PolicyInstance
mkPolicy pt fAF fBEN fSP =
  PolicyInstance { piNQQ = fAF (ptNQQ pt)
                 , piZE  = fAF (ptZE  pt)
                 , piGPZ = fAF (ptGPZ pt)
                 , piEN  = case fBEN of
                             Nothing -> Nothing
                             Just _  -> Just $ PIBEN
                               { piqnuv  = fAF $ pqnuv  (ptEN pt)
                               , piqnvph = fAF $ pqnvph (ptEN pt)
                               , pizn    = fAF $ pzn    (ptEN pt)
                               , pitjg   = fAF $ ptjg   (ptEN pt)
                               , pisfs   = fAF $ psfs   (ptEN pt) }
                 , piSP  = case fSP of
                             Nothing -> Nothing
                             Just f  -> Just $ PISP
                               { pispsoq = f $ spsoq (ptSP pt)
                               , pispzn  = f $ spzn  (ptSP pt)
                               , pispusr = f $ spusr (ptSP pt)
                               , pispeo  = f $ speo  (ptSP pt) }
                 }
