%
% (c) The GRASP/AQUA Project, Glasgow University, 1998
%
\section[TypeRep]{Type - friends' interface}

\begin{code}
module TypeRep (
	TyThing(..), 
	Type(..), TyNote(..), 		-- Representation visible 
	PredType(..),	 		-- to friends
	
 	Kind, ThetaType,		-- Synonyms
	TyVarSubst,

	superKind, superBoxity,				-- KX and BX respectively
	liftedBoxity, unliftedBoxity, 			-- :: BX
	openKindCon, 					-- :: KX
	typeCon,					-- :: BX -> KX
	liftedTypeKind, unliftedTypeKind, openTypeKind,	-- :: KX
	isLiftedTypeKind, isUnliftedTypeKind, isOpenTypeKind,
	mkArrowKind, mkArrowKinds,			-- :: KX -> KX -> KX

	funTyCon,

	-- Pretty-printing
	pprKind, pprParendKind,
	pprType, pprParendType,
	pprPred, pprTheta, pprThetaArrow, pprClassPred
    ) where

#include "HsVersions.h"

import {-# SOURCE #-} DataCon( DataCon, dataConName )

-- friends:
import Var	  ( Id, TyVar, tyVarKind )
import VarEnv     ( TyVarEnv )
import VarSet     ( TyVarSet )
import Name	  ( Name, NamedThing(..), mkWiredInName, mkInternalName )
import OccName	  ( mkOccFS, mkKindOccFS, tcName )
import BasicTypes ( IPName, tupleParens )
import TyCon	  ( TyCon, KindCon, mkFunTyCon, mkKindCon, mkSuperKindCon, isNewTyCon,
		    tyConArity, tupleTyConBoxity, isTupleTyCon, tyConName )
import Class	  ( Class )

-- others
import PrelNames	( gHC_PRIM, kindConKey, boxityConKey, liftedConKey, 
			  unliftedConKey, typeConKey, anyBoxConKey, 
			  funTyConKey, listTyConKey, parrTyConKey,
			  hasKey
			)
import SrcLoc		( noSrcLoc )
import Outputable
\end{code}

%************************************************************************
%*									*
\subsection{Type Classifications}
%*									*
%************************************************************************

A type is

	*unboxed*	iff its representation is other than a pointer
			Unboxed types are also unlifted.

	*lifted*	A type is lifted iff it has bottom as an element.
			Closures always have lifted types:  i.e. any
			let-bound identifier in Core must have a lifted
			type.  Operationally, a lifted object is one that
			can be entered.

			Only lifted types may be unified with a type variable.

	*algebraic*	A type with one or more constructors, whether declared
			with "data" or "newtype".   
			An algebraic type is one that can be deconstructed
			with a case expression.  
			*NOT* the same as lifted types,  because we also 
			include unboxed tuples in this classification.

	*data*		A type declared with "data".  Also boxed tuples.

	*primitive*	iff it is a built-in type that can't be expressed
			in Haskell.

Currently, all primitive types are unlifted, but that's not necessarily
the case.  (E.g. Int could be primitive.)

Some primitive types are unboxed, such as Int#, whereas some are boxed
but unlifted (such as ByteArray#).  The only primitive types that we
classify as algebraic are the unboxed tuples.

examples of type classifications:

Type		primitive	boxed		lifted		algebraic    
-----------------------------------------------------------------------------
Int#,		Yes		No		No		No
ByteArray#	Yes		Yes		No		No
(# a, b #)	Yes		No		No		Yes
(  a, b  )	No		Yes		Yes		Yes
[a]		No		Yes		Yes		Yes



	----------------------
	A note about newtypes
	----------------------

Consider
	newtype N = MkN Int

Then we want N to be represented as an Int, and that's what we arrange.
The front end of the compiler [TcType.lhs] treats N as opaque, 
the back end treats it as transparent [Type.lhs].

There's a bit of a problem with recursive newtypes
	newtype P = MkP P
	newtype Q = MkQ (Q->Q)

Here the 'implicit expansion' we get from treating P and Q as transparent
would give rise to infinite types, which in turn makes eqType diverge.
Similarly splitForAllTys and splitFunTys can get into a loop.  

Solution: 

* Newtypes are always represented using NewTcApp, never as TyConApp.

* For non-recursive newtypes, P, treat P just like a type synonym after 
  type-checking is done; i.e. it's opaque during type checking (functions
  from TcType) but transparent afterwards (functions from Type).  
  "Treat P as a type synonym" means "all functions expand NewTcApps 
  on the fly".

  Applications of the data constructor P simply vanish:
	P x = x
  

* For recursive newtypes Q, treat the Q and its representation as 
  distinct right through the compiler.  Applications of the data consructor
  use a coerce:
	Q = \(x::Q->Q). coerce Q x
  They are rare, so who cares if they are a tiny bit less efficient.

The typechecker (TcTyDecls) identifies enough type construtors as 'recursive'
to cut all loops.  The other members of the loop may be marked 'non-recursive'.


%************************************************************************
%*									*
\subsection{The data type}
%*									*
%************************************************************************


\begin{code}
type SuperKind = Type
type Kind      = Type

type TyVarSubst = TyVarEnv Type

data Type
  = TyVarTy TyVar

  | AppTy
	Type		-- Function is *not* a TyConApp
	Type

  | TyConApp		-- Application of a TyCon
	TyCon		-- *Invariant* saturated appliations of FunTyCon and
			-- 	synonyms have their own constructors, below.
	[Type]		-- Might not be saturated.

  | NewTcApp		-- Application of a NewType TyCon.   All newtype applications
	TyCon		-- show up like this until they are fed through newTypeRep,
			-- which returns 
			--	* an ordinary TyConApp for non-saturated, 
			--	 or recursive newtypes
			--
			--	* the representation type of the newtype for satuarted, 
			--	  non-recursive ones
			-- [But the result of a call to newTypeRep is always consumed
			--  immediately; it never lives on in another type.  So in any
			--  type, newtypes are always represented with NewTcApp.]
	[Type]		-- Might not be saturated.

  | FunTy		-- Special case of TyConApp: TyConApp FunTyCon [t1,t2]
	Type
	Type

  | ForAllTy		-- A polymorphic type
	TyVar
	Type	

  | PredTy		-- A high level source type 
	PredType	-- ...can be expanded to a representation type...

  | NoteTy 		-- A type with a note attached
	TyNote
	Type		-- The expanded version

data TyNote
  = FTVNote TyVarSet	-- The free type variables of the noted expression

  | SynNote Type	-- Used for type synonyms
			-- The Type is always a TyConApp, and is the un-expanded form.
			-- The type to which the note is attached is the expanded form.
\end{code}

-------------------------------------
 		Source types

A type of the form
	PredTy p
represents a value whose type is the Haskell predicate p, 
where a predicate is what occurs before the '=>' in a Haskell type.
It can be expanded into its representation, but: 

	* The type checker must treat it as opaque
	* The rest of the compiler treats it as transparent

Consider these examples:
	f :: (Eq a) => a -> Int
	g :: (?x :: Int -> Int) => a -> Int
	h :: (r\l) => {r} => {l::Int | r}

Here the "Eq a" and "?x :: Int -> Int" and "r\l" are all called *predicates*
Predicates are represented inside GHC by PredType:

\begin{code}
data PredType 
  = ClassP Class [Type]		-- Class predicate
  | IParam (IPName Name) Type	-- Implicit parameter

type ThetaType = [PredType]
\end{code}

(We don't support TREX records yet, but the setup is designed
to expand to allow them.)

A Haskell qualified type, such as that for f,g,h above, is
represented using 
	* a FunTy for the double arrow
	* with a PredTy as the function argument

The predicate really does turn into a real extra argument to the
function.  If the argument has type (PredTy p) then the predicate p is
represented by evidence (a dictionary, for example, of type (predRepTy p).


%************************************************************************
%*									*
\subsection{Kinds}
%*									*
%************************************************************************

Kinds
~~~~~
kind :: KX = kind -> kind

           | Type liftedness	-- (Type *) is printed as just *
				-- (Type #) is printed as just #

           | OpenKind		-- Can be lifted or unlifted
				-- Printed '?'

           | kv			-- A kind variable; *only* happens during kind checking

boxity :: BX = *	-- Lifted
	     | #	-- Unlifted
	     | bv	-- A boxity variable; *only* happens during kind checking

There's a little subtyping at the kind level:  
	forall b. Type b <: OpenKind

That is, a type of kind (Type b) is OK in a context requiring an OpenKind

OpenKind, written '?', is used as the kind for certain type variables,
in two situations:

1.  The universally quantified type variable(s) for special built-in 
    things like error :: forall (a::?). String -> a. 
    Here, the 'a' can be instantiated to a lifted or unlifted type.  

2.  Kind '?' is also used when the typechecker needs to create a fresh
    type variable, one that may very well later be unified with a type.
    For example, suppose f::a, and we see an application (f x).  Then a
    must be a function type, so we unify a with (b->c).  But what kind
    are b and c?  They can be lifted or unlifted types, or indeed type schemes,
    so we give them kind '?'.

    When the type checker generalises over a bunch of type variables, it
    makes any that still have kind '?' into kind '*'.  So kind '?' is never
    present in an inferred type.


------------------------------------------
Define  KX, the type of a kind
	BX, the type of a boxity

\begin{code}
superKindName    = kindQual FSLIT("KX") kindConKey
superBoxityName  = kindQual FSLIT("BX") boxityConKey
liftedConName    = kindQual FSLIT("*") liftedConKey
unliftedConName  = kindQual FSLIT("#") unliftedConKey
openKindConName  = kindQual FSLIT("?") anyBoxConKey
typeConName	 = kindQual FSLIT("Type") typeConKey

kindQual str uq = mkInternalName uq (mkKindOccFS tcName str) noSrcLoc
	-- Kinds are not z-encoded in interface file, hence mkKindOccFS
	-- And they don't come from any particular module; indeed we always
	-- want to print them unqualified.  Hence the InternalName.
\end{code}

\begin{code}
superKind :: SuperKind 		-- KX, the type of all kinds
superKind = TyConApp (mkSuperKindCon superKindName) []

superBoxity :: SuperKind		-- BX, the type of all boxities
superBoxity = TyConApp (mkSuperKindCon superBoxityName) []
\end{code}

------------------------------------------
Define boxities: @*@ and @#@

\begin{code}
liftedBoxity, unliftedBoxity :: Kind		-- :: BX
liftedBoxity   = TyConApp liftedBoxityCon   []
unliftedBoxity = TyConApp unliftedBoxityCon []

liftedBoxityCon   = mkKindCon liftedConName superBoxity
unliftedBoxityCon = mkKindCon unliftedConName superBoxity
\end{code}

------------------------------------------
Define kinds: Type, Type *, Type #, OpenKind

\begin{code}
typeCon :: KindCon	-- :: BX -> KX
typeCon     = mkKindCon typeConName (superBoxity `FunTy` superKind)

liftedTypeKind, unliftedTypeKind, openTypeKind :: Kind	-- Of superkind superKind

liftedTypeKind   = TyConApp typeCon [liftedBoxity]
unliftedTypeKind = TyConApp typeCon [unliftedBoxity]

openKindCon     = mkKindCon openKindConName superKind
openTypeKind    = TyConApp openKindCon []
\end{code}

\begin{code}
isLiftedTypeKind, isUnliftedTypeKind, isOpenTypeKind :: Kind -> Bool
isLiftedTypeKind (TyConApp tc [TyConApp bc []])   = tyConName tc == typeConName && 
						    tyConName bc == liftedConName
isUnliftedTypeKind (TyConApp tc [TyConApp bc []]) = tyConName tc == typeConName && 
						    tyConName bc == unliftedConName
isOpenTypeKind (TyConApp tc []) = tyConName tc == openKindConName

isSuperKind (TyConApp tc []) = tyConName tc == superKindName
\end{code}

------------------------------------------
Define arrow kinds

\begin{code}
mkArrowKind :: Kind -> Kind -> Kind
mkArrowKind k1 k2 = k1 `FunTy` k2

mkArrowKinds :: [Kind] -> Kind -> Kind
mkArrowKinds arg_kinds result_kind = foldr mkArrowKind result_kind arg_kinds
\end{code}


%************************************************************************
%*									*
			TyThing
%*									*
%************************************************************************

Despite the fact that DataCon has to be imported via a hi-boot route, 
this module seems the right place for TyThing, because it's needed for
funTyCon and all the types in TysPrim.

\begin{code}
data TyThing = AnId     Id
	     | ADataCon DataCon
	     | ATyCon   TyCon
	     | AClass   Class

instance Outputable TyThing where
  ppr (AnId   id)   = ptext SLIT("AnId")     <+> ppr id
  ppr (ATyCon tc)   = ptext SLIT("ATyCon")   <+> ppr tc
  ppr (AClass cl)   = ptext SLIT("AClass")   <+> ppr cl
  ppr (ADataCon dc) = ptext SLIT("ADataCon") <+> ppr (dataConName dc)

instance NamedThing TyThing where	-- Can't put this with the type
  getName (AnId id)     = getName id	-- decl, because the DataCon instance
  getName (ATyCon tc)   = getName tc	-- isn't visible there
  getName (AClass cl)   = getName cl
  getName (ADataCon dc) = dataConName dc
\end{code}


%************************************************************************
%*									*
\subsection{Wired-in type constructors
%*									*
%************************************************************************

We define a few wired-in type constructors here to avoid module knots

\begin{code}
funTyCon = mkFunTyCon funTyConName (mkArrowKinds [liftedTypeKind, liftedTypeKind] liftedTypeKind)
	-- You might think that (->) should have type (? -> ? -> *), and you'd be right
	-- But if we do that we get kind errors when saying
	--	instance Control.Arrow (->)
	-- becuase the expected kind is (*->*->*).  The trouble is that the
	-- expected/actual stuff in the unifier does not go contra-variant, whereas
	-- the kind sub-typing does.  Sigh.  It really only matters if you use (->) in
	-- a prefix way, thus:  (->) Int# Int#.  And this is unusual.

funTyConName = mkWiredInName gHC_PRIM
			(mkOccFS tcName FSLIT("(->)"))
			funTyConKey
			Nothing 		-- No parent object
			(ATyCon funTyCon)	-- Relevant TyCon
\end{code}


%************************************************************************
%*									*
\subsection{The external interface}
%*									*
%************************************************************************

@pprType@ is the standard @Type@ printer; the overloaded @ppr@ function is
defined to use this.  @pprParendType@ is the same, except it puts
parens around the type, except for the atomic cases.  @pprParendType@
works just by setting the initial context precedence very high.

\begin{code}
data Prec = TopPrec 	-- No parens
	  | FunPrec 	-- Function args; no parens for tycon apps
	  | TyConPrec 	-- Tycon args; no parens for atomic
	  deriving( Eq, Ord )

maybeParen :: Prec -> Prec -> SDoc -> SDoc
maybeParen ctxt_prec inner_prec pretty
  | ctxt_prec < inner_prec = pretty
  | otherwise		   = parens pretty

------------------
pprType, pprParendType :: Type -> SDoc
pprType       ty = ppr_type TopPrec   ty
pprParendType ty = ppr_type TyConPrec ty

------------------
pprKind, pprParendKind :: Kind -> SDoc
pprKind       k = ppr_kind TopPrec k
pprParendKind k = ppr_kind TyConPrec k

------------------
pprPred :: PredType -> SDoc
pprPred (ClassP cls tys) = pprClassPred cls tys
pprPred (IParam ip ty)   = ppr ip <> dcolon <> pprType ty

pprClassPred :: Class -> [Type] -> SDoc
pprClassPred clas tys = ppr clas <+> sep (map pprParendType tys)

pprTheta :: ThetaType -> SDoc
pprTheta theta = parens (sep (punctuate comma (map pprPred theta)))

pprThetaArrow :: ThetaType -> SDoc
pprThetaArrow theta 
  | null theta = empty
  | otherwise  = parens (sep (punctuate comma (map pprPred theta))) <+> ptext SLIT("=>")

------------------
instance Outputable Type where
    ppr ty = pprType ty

instance Outputable PredType where
    ppr = pprPred

instance Outputable name => OutputableBndr (IPName name) where
    pprBndr _ n = ppr n	-- Simple for now

------------------
	-- OK, here's the main printer

ppr_type :: Prec -> Type -> SDoc
ppr_type p (TyVarTy tv)      	      = ppr tv
ppr_type p (PredTy pred)     	      = braces (ppr pred)
ppr_type p (NoteTy (SynNote ty1) ty2) = ppr_type p ty1
ppr_type p (NoteTy other         ty2) = ppr_type p ty2

ppr_type p (TyConApp tc tys) = ppr_tc_app p tc tys
ppr_type p (NewTcApp tc tys) = ifPprDebug (ptext SLIT("<nt>")) <> 
			       ppr_tc_app p tc tys

ppr_type p (AppTy t1 t2) = maybeParen p TyConPrec $
			   pprType t1 <+> ppr_type TyConPrec t2

ppr_type p (FunTy ty1 ty2)
  = -- We don't want to lose synonyms, so we mustn't use splitFunTys here.
    maybeParen p FunPrec $
    sep (ppr_type FunPrec ty1 : ppr_fun_tail ty2)
  where
    ppr_fun_tail (FunTy ty1 ty2) = (arrow <+> ppr_type FunPrec ty1) : ppr_fun_tail ty2
    ppr_fun_tail other_ty        = [arrow <+> pprType other_ty]

ppr_type p ty@(ForAllTy _ _)  
  = maybeParen p FunPrec $
    sep [pprForAll tvs, pprThetaArrow ctxt, pprType tau]
  where
    (tvs,  rho) = split1 [] ty
    (ctxt, tau) = split2 [] rho

    split1 tvs (ForAllTy tv ty) = split1 (tv:tvs) ty
    split1 tvs ty		= (reverse tvs, ty)
 
    split2 ps (PredTy p `FunTy` ty) = split2 (p:ps) ty
    split2 ps ty		    = (reverse ps, ty)

ppr_tc_app :: Prec -> TyCon -> [Type] -> SDoc
ppr_tc_app p tc [ty] 
  | tc `hasKey` listTyConKey = brackets (pprType ty)
  | tc `hasKey` parrTyConKey = ptext SLIT("[:") <> pprType ty <> ptext SLIT(":]")
ppr_tc_app p tc tys
  | isTupleTyCon tc && tyConArity tc == length tys
  = tupleParens (tupleTyConBoxity tc) (sep (punctuate comma (map pprType tys)))
  | otherwise
  = maybeParen p TyConPrec $
    ppr tc <+> sep (map (ppr_type TyConPrec) tys)

-------------------
pprForAll tvs = ptext SLIT("forall") <+> sep (map pprTvBndr tvs) <> dot

pprTvBndr tv | isLiftedTypeKind kind = ppr tv
	     | otherwise	     = parens (ppr tv <+> dcolon <+> pprKind kind)
	     where
	       kind = tyVarKind tv


-------------------
ppr_kind :: Prec -> Kind -> SDoc
ppr_kind p k
  | isOpenTypeKind k     = ptext SLIT("?")
  | isLiftedTypeKind k   = ptext SLIT("*")
  | isUnliftedTypeKind k = ptext SLIT("#")
ppr_kind p (TyVarTy tv)  = ppr tv
ppr_kind p (FunTy k1 k2) = maybeParen p FunPrec $
			 	  sep [ ppr_kind FunPrec k1, arrow <+> pprKind k2]
ppr_kind p other = ptext SLIT("STRANGE KIND:") <+> ppr_type p other
\end{code}

