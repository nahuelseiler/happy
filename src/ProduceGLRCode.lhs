Module for producing GLR (Tomita) parsing code.
This module is designed as an extension to the Haskell parser generator Happy.

(c) University of Durham, Ben Medlock 2001
	-- initial code, for structure parsing 
(c) University of Durham, Paul Callaghan 2004
	-- extension to semantic rules, and various optimisations

$Id: ProduceGLRCode.lhs,v 1.7 2004/10/27 23:01:58 paulcc Exp $

%-----------------------------------------------------------------------------

> module ProduceGLRCode ( produceGLRParser
>                       , DecodeOption(..)
>                       , FilterOption(..)
>                       , GhcExts(..)
>                       , Options
>                       ) where

> import GenUtils ( fst3, thd3, mapDollarDollar )
> import Grammar
> import Array
> import Maybe ( fromJust )
> import Char ( isUpper, isSpace )
> import List ( nub, (\\) )

%-----------------------------------------------------------------------------
File and Function Names

> base_template td = td ++ "/GLR_Base"		-- NB Happy uses / too
> lib_template  td = td ++ "/GLR_Lib"		-- Windows accepts this?

---
prefix for production names, to avoid name clashes

> prefix = "G_"

%-----------------------------------------------------------------------------
This type represents choice of decoding style for the result

> data DecodeOption
>  = TreeDecode 
>  | LabelDecode

---
This type represents whether filtering done or not

> data FilterOption
>  = NoFiltering
>  | UseFiltering

---
This type represents whether GHC extensions are used or not
 - extra values are imports and ghc options reqd

> data GhcExts
>  = NoGhcExts
>  | UseGhcExts String String 		-- imports and options

---
this is where the exts matter

> show_st :: GhcExts -> {-State-}Int -> String
> show_st UseGhcExts{} = (++"#") . show
> show_st NoGhcExts    = show

---

> type Options = (DecodeOption, FilterOption, GhcExts)


%-----------------------------------------------------------------------------
Main exported function

> produceGLRParser
>        :: FilePath 	  -- Output file name
>	 -> String 	  -- Templates directory
>	 -> ActionTable   -- LR tables
>	 -> GotoTable  	  -- LR tables 
>	 -> Maybe String  -- Module header
>	 -> Maybe String  -- User-defined stuff (token DT, lexer etc.)
>	 -> Options       -- selecting code-gen style
>	 -> Grammar 	  -- Happy Grammar
>	 -> IO ()

> produceGLRParser outfilename template_dir action goto header trailer options g
>  = do
>     let basename  = takeWhile (/='.') outfilename
>     let gsMap = mkGSymMap g
>     let tbls  = mkTbls action goto gsMap (thd3 options) g
>     (parseName,_,_) <- case starts g of
>                          [s] -> return s
>                          s:_ -> do 
>                                    putStrLn "GLR-Happy doesn't support multiple start points (yet)"
>                                    putStrLn "Defaulting to first start point."
>                                    return s
>     mkFiles basename tbls parseName template_dir header trailer options g


%-----------------------------------------------------------------------------
"mkFiles" generates the files containing the Tomita parsing code.
It produces two files - one for the data (small template), and one for 
the driver and data strs (large template).

> mkFiles :: FilePath 	  -- Root of Output file name 
>	 -> String   	  -- LR tables - generated by 'mkTbls'
>	 -> String   	  -- Start parse function name
>	 -> String 	  -- Templates directory
>	 -> Maybe String  -- Module header
>	 -> Maybe String  -- User-defined stuff (token DT, lexer etc.)
>        -> Options       -- selecting code-gen style
>	 -> Grammar 	  -- Happy Grammar
>	 -> IO ()
>
> mkFiles basename tables start templdir header trailer options g
>  = do
>	let (ext,imps,opts) = case thd3 options of 
>		    		UseGhcExts is os -> ("-ghc", is, os)
>		    		_                -> ("", "", "")
>	base <- readFile (base_template templdir)
>	case trailer of
>	  Nothing  -> error "Incomplete grammar specification!"
>	  Just str -> writeFile (basename ++ "Data.hs") (content base opts str)

>	lib <- readFile (lib_template templdir ++ ext)
>	writeFile (basename ++ ".hs") (lib_content imps opts lib)
>  where
>   mod_name = reverse $ takeWhile (`notElem` "\\/") $ reverse basename
>   data_mod = mod_name ++ "Data"
>   content tomitaStr opts userInfo
>    = unlines [ "{-# OPTIONS " ++ opts ++ " #-}"
>	       , "module " ++ data_mod ++ " where"
>	       , moduleHdr
>	       , tomitaStr
>	       , userInfo
>	       , let beginning = moduleHdr ++ tomitaStr ++ userInfo
>	             position = 2 + length (lines beginning)
>	         in "{-# LINE " ++ show position ++ " "
>		                  ++ show (basename ++ "Data.hs") ++ "#-}"
>	       , mkGSymbols g 
>	       , sem_def
>	       , mkSemObjects options sem_info
>	       , mkDecodeUtils options sem_info
>	       -- , unlines $ map show sem_info
>	       , typeForToks 
>	       , tables ]
>   typeForToks = unlines [ "type UserDefTok = " ++ token_type g ]
>   moduleHdr
>    = case header of
>	  Nothing -> ""
>	  Just h  -> h
>   (sem_def, sem_info) = mkGSemType options g

>   lib_content imps opts lib_text
>    = let (pre,drop_me:post) = break (== "fakeimport DATA") $ lines lib_text
>      in 
>      unlines [ "{-# OPTIONS " ++ opts ++ " #-}"
>	       , "module " ++ mod_name ++ "("
>	       , case lexer g of 
>                  Nothing     -> ""
>                  Just (lf,_) -> "\t" ++ lf ++ ","
>	       , "\t" ++ start
>	       , ""
>	       , unlines pre
>	       , imps
>	       , "import " ++ data_mod
>	       , start ++ " = glr_parse " 
>	       , "use_filtering = " ++ show use_filtering
>	       , "top_symbol = " ++ prefix ++ start_prod
>	       , unlines post
>	       ]
>   start_prod = token_names g ! (let (_,_,i) = head $ starts g in i)
>   use_filtering = case options of (_, UseFiltering,_) -> True
>                                   _                   -> False


%-----------------------------------------------------------------------------
Formats the tables as code.

> mkTbls :: ActionTable		-- Action table from Happy
>	 -> GotoTable 		-- Goto table from Happy
>	 -> [(Int,String)] 	-- Internal GSymbol map (see below)
>	 -> GhcExts 		-- Use unboxed values?
>	 -> Grammar 		-- Happy Grammar
>	 -> String
>
> mkTbls action goto gsMap exts g
>  = unlines [ writeActionTbl action gsMap exts g
>	     , writeGotoTbl   goto   gsMap exts ]


%-----------------------------------------------------------------------------
Create a mapping of Happy grammar symbol integers to the data representation
that will be used for them in the GLR parser.

> mkGSymMap :: Grammar -> [(Name,String)]
> mkGSymMap g
>  = 	[ (i, prefix ++ (token_names g) ! i) 
>	| i <- user_non_terminals g ]	-- Non-terminals
>    ++ [ (i, "HappyTok (" ++ mkMatch tok ++ ")")
>	| (i,tok) <- token_specs g ]	-- Tokens (terminals)
>    ++ [(eof_term g,"HappyEOF")]	-- EOF symbol (internal terminal)
>  where
>   mkMatch tok = case mapDollarDollar tok of 
>                   Nothing -> tok
>                   Just fn -> fn "_"

> toGSym gsMap i 
>  = case lookup i gsMap of
>     Nothing -> error $ "No representation for symbol " ++ show i
>     Just g  -> g 


%-----------------------------------------------------------------------------
Take the ActionTable from Happy and turn it into a String representing a
function that can be included as the action table in the GLR parser.
It also shares identical reduction values as CAFs

> writeActionTbl :: ActionTable -> [(Int,String)] -> GhcExts -> Grammar -> String
> writeActionTbl acTbl gsMap exts g
>  = unlines $ mkLines ++ errorLine ++ mkReductions
>  where
>   name      = "action"
>   mkLines   = concatMap mkState (assocs acTbl)
>   errorLine = [ name ++ " _ _ = Error" ]
>   mkState (i,arr) 
>    = filter (/="") $ map (mkLine i) (assocs arr)
>
>   mkLine state (symInt,action)
>    = case action of
>       LR'Fail     -> ""
>       LR'MustFail -> ""
>       _	    -> unwords [ startLine , mkAct action ]
>    where
>     startLine 
>      = unwords [ name , show_st exts state, "(" , getTok , ") =" ]
>     getTok = let tok = toGSym gsMap symInt
>              in case mapDollarDollar tok of
>                   Nothing -> tok
>                   Just f  -> f "_"
>   mkAct act
>    = case act of
>       LR'Shift newSt _ -> "Shift " ++ show newSt ++ " []"
>       LR'Reduce r    _ -> "Reduce " ++ "[" ++ mkRed r ++ "]" 
>       LR'Accept	 -> "Accept"
>       LR'Multiple rs (LR'Shift st _) 
>	                 -> "Shift " ++ show st ++ " " ++ mkReds rs
>       LR'Multiple rs r@(LR'Reduce{})
>	                 -> "Reduce " ++ mkReds (r:rs)
>    where
>     rule r  = lookupProdNo g r
>     mkReds rs = "[" ++ tail (concat [ "," ++ mkRed r | LR'Reduce r _ <- rs ]) ++ "]"

>   mkRed r = "red_" ++ show r
>   mkReductions = [ mkRedDefn p | p@(_,(n,_,_,_)) <- zip [0..] $ productions g 
>                                , n `notElem` start_productions g ]

>   mkRedDefn (r, (lhs_id, rhs_ids, (code,dollar_vars), _))
>    = mkRed r ++ " = ("++ lhs ++ "," ++ show arity ++ " :: Int," ++ sem ++")"
>      where
>         lhs = toGSym gsMap $ lhs_id
>         arity = length rhs_ids
>         sem = "sem_" ++ show r


%-----------------------------------------------------------------------------
Do the same with the Happy goto table.

> writeGotoTbl :: GotoTable -> [(Int,String)] -> GhcExts -> String
> writeGotoTbl goTbl gsMap exts
>  = concat $ mkLines ++ [errorLine]
>  where
>   name    = "goto"
>   errorLine = "goto _ _ = " ++ show_st exts (negate 1) 
>   mkLines = map mkState (assocs goTbl) 
>
>   mkState (i,arr) 
>    = unlines $ filter (/="") $ map (mkLine i) (assocs arr)
>
>   mkLine state (ntInt,goto)
>    = case goto of
>       NoGoto  -> ""
>       Goto st -> unwords [ startLine , show_st exts st ]
>    where
>     startLine 
>      = unwords [ name , show_st exts state, getGSym , "=" ]
>     getGSym = toGSym gsMap ntInt


%-----------------------------------------------------------------------------
Create the 'GSymbol' ADT for the symbols in the grammar

> mkGSymbols :: Grammar -> String
> mkGSymbols g 
>  = unlines [ dec 
>	     , eof
>	     , tok	
>	     , unlines [ " | " ++ prefix ++ sym ++ " " | sym <- syms ] 
>	     , der ]
>    -- ++ eq_inst
>    -- ++ ord_inst
>  where
>   dec  = "data GSymbol"
>   eof  = " = HappyEOF" 
>   tok  = " | HappyTok {-!Int-} (" ++ token_type g ++ ")"
>   der  = "   deriving (Show,Eq,Ord)"
>   syms = [ token_names g ! i | i <- user_non_terminals g ]

NOTES: 
Was considering avoiding use of Eq/Ord over tokens, but this then means
hand-coding the Eq/Ord classes since we're over-riding the usual order
except in one case. 

maybe possible to form a union and do some juggling, but this isn't that
easy, eg input type of "action". 

plus, issues about how token info gets into TreeDecode sem values - which
might be tricky to arrange.
<>   eq_inst = "instance Eq GSymbol where" 
<>           : "\tHappyTok i _ == HappyTok j _ = i == j" 
<>           : [ "\ti == j = fromEnum i == fromEnum j" 



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
Semantic actions on rules.

These are stored in a union type "GSem", and the semantic values are held 
on the branches created at the appropriate reduction. 

"GSem" type has one constructor per distinct type of semantic action and
pattern of child usage. 


%-----------------------------------------------------------------------------
Creating a type for storing semantic rules
 - also collects information on code structure and constructor names, for
   use in later stages.

> type SemInfo 
>  = [(String, String, [Int], [((Int,Int), ([(Int,String)],String), [Int])])]

> mkGSemType :: Options -> Grammar -> (String, SemInfo)
> mkGSemType (TreeDecode,_,_) g 
>  = (def, map snd syms)
>  where
>   def  = unlines $    "data GSem"
>	           :    " = NoSem"
>	           :  ( " | SemTok (" ++  token_type g ++ ")" )
>	           :  [ " | " ++ sym ++ " " | sym <- map fst syms ] 
>	           ++   "instance Show GSem where"
>	           :  [ "    show " ++ c ++ "{} = " ++ show c 
>                     | (_,c,_,_) <- map snd syms ]

>   syms = [ (c_name ++ " (" ++ ty ++ ")", (rty, c_name, mask, prod_info))
>          | (i,this@(mask,args,rty)) <- zip [0..] (nub $ map fst info)
>          					-- find unique types (plus mask)
>          , let c_name = "Sem_" ++ show i
>          , let ty = foldr (\l r -> l ++ " -> " ++ r) rty args 

>          , let code_info = [ j_code | (that, j_code) <- info, this == that ]
>          , let prod_info = [ ((i,k), code, js) 
>	                     | (k,code) <- zip [0..] (nub $ map snd code_info)
>	                     , let js = [ j | (j,code2) <- code_info
>                                           , code == code2 ]
>                            ]
>	     -- collect specific info about productions with this type
>          ]

>   info = [ ((var_mask, args, i_ty), (j,(ts_pats,code)))
>          | i <- user_non_terminals g 
>          , let i_ty = typeOf i
>          , j <- lookupProdsOfName g i  -- all prod numbers
>          , let (_,ts,(raw_code,dollar_vars),_) = lookupProdNo g j
>          , let var_mask = map (\x -> x - 1) $ reverse dollar_vars
>              -- have to reverse, since Happy-LR expects reverse stacked vars
>          , let args = [ typeOf $ ts !! v | v <- var_mask ]
>	   , let code | all isSpace raw_code = "()"
>                     | otherwise            = raw_code
>	   , let ts_pats = [ (k,c) | k <- reverse dollar_vars
>	                           , (t,c) <- token_specs g
>	                           , ts !! (k - 1) == t ]
>          ]

>   typeOf n | n `elem` terminals g = token_type g
>            | otherwise            = case types g ! n of
>                                       Nothing -> "()"		-- default
>                                       Just t  -> t

> -- NB expects that such labels are Showable
> mkGSemType (LabelDecode,_,_) g 
>  = (def, map snd syms)
>  where
>   def  = unlines $    "data GSem"
>	           :    " = NoSem"
>	           :  ( " | SemTok (" ++  token_type g ++ ")" )
>	           :  [ " | " ++ sym ++ " " | sym <- map fst syms ] 
>	           ++ [ "   deriving (Show)" ]

>   syms = [ (c_name ++ " (" ++ ty ++ ")", (ty, c_name, mask, prod_info))
>          | (i,this@(mask,ty)) <- zip [0..] (nub $ map fst info)
>          					-- find unique types
>          , let c_name = "Sem_" ++ show i
>          , let code_info = [ j_code | (that, j_code) <- info, this == that ]
>          , let prod_info = [ ((i,k), code, js) 
>	                     | (k,code) <- zip [0..] (nub $ map snd code_info)
>	                     , let js = [ j | (j,code2) <- code_info
>                                           , code == code2 ]

>                            ]
>	     -- collect specific info about productions with this type
>          ]

>   info = [ ((var_mask,i_ty), (j,(ts_pats,code)))
>          | i <- user_non_terminals g
>          , let i_ty = typeOf i
>          , j <- lookupProdsOfName g i  -- all prod numbers
>          , let (_,ts,(code,dollar_vars),_) = lookupProdNo g j
>          , let var_mask = map (\x -> x - 1) $ reverse dollar_vars
>              -- have to reverse, since Happy-LR expects reverse stacked vars
>	   , let ts_pats = [ (k,c) | k <- reverse dollar_vars
>	                           , (t,c) <- token_specs g
>	                           , ts !! (k - 1) == t ]
>          ]

>   typeOf n = case types g ! n of
>                Nothing -> "()"		-- default
>                Just t  -> t


%---------------------------------------
Creates the appropriate semantic values.
 - for label-decode, these are the code, but abstracted over the child indices
 - for tree-decode, these are the code abstracted over the children's values

> mkSemObjects :: Options -> SemInfo -> String 
> mkSemObjects (LabelDecode,filter_opt,_) sem_info
>  = unlines 
>  $ [ mkSemFn_Name ij ++ " ns@(" ++ pat ++ "happy_rest) = " 
>	++ " Branch (" ++ c_name ++ " (" ++ code ++ ")) " ++ nodes filter_opt
>    | (ty, c_name, mask, prod_info) <- sem_info
>    , (ij, (pats,code), ps) <- prod_info 
>    , let pat | null mask = ""
>              | otherwise = concatMap (\v -> mk_tok_binder pats (v+1) ++ ":")
>                                      [0..maximum mask]

>    , let nodes NoFiltering  = "ns"
>          nodes UseFiltering = "(" ++ foldr (\l -> mkHappyVar (l+1) . showChar ':') "[])" mask
>    ]
>    ++ 
>    sem_placeholders sem_info
>    where
>	mk_tok_binder pats v 
>	 = mk_binder (\s -> "(_,_,HappyTok (" ++ s ++ "))") pats v ""

TODO: FILTERING: should really GC the dropped ones!


> mkSemObjects (TreeDecode,filter_opt,_) sem_info
>  = unlines 
>  $ [ mkSemFn_Name ij ++ " ns@(" ++ pat ++ "happy_rest) = " 
>      ++ " Branch (" ++ c_name ++ " (" ++ sem ++ ")) " 
>      ++ nodes filter_opt
>    | (ty, c_name, mask, prod_info) <- sem_info
>    , (ij, (pats,code), _) <- prod_info 
>    , let sem = foldr (\v t -> mk_lambda pats (v + 1) "" ++ t) code mask
>    , let pat | null mask = ""
>              | otherwise = concatMap (\v -> mkHappyVar (v+1) ":")
>                                      [0..maximum mask]
>    , let nodes NoFiltering  = "ns"
>          nodes UseFiltering = "(" ++ foldr (\l -> mkHappyVar (l+1) . showChar ':') "[])" mask
>    ] 
>    ++ 
>    sem_placeholders sem_info

> mk_lambda pats v
>  = (\s -> "\\(" ++ s ++ ") -> ") . mk_binder id pats v

> mk_binder wrap pats v
>  = case lookup v pats of
>	Nothing -> mkHappyVar v 
>	Just p  -> case mapDollarDollar p of 
>	              Nothing -> wrap . showString p
>	              Just fn -> wrap . fn . mkHappyVar v 


> mkSemFn_Name (i,j) = "semfn_" ++ show i ++ "_" ++ show j

> sem_placeholders sem_info
>  = [ "sem_" ++ show p ++ " = " ++ mkSemFn_Name ij
>    | (ty, c_name, mask, prod_info) <- sem_info
>    , (ij, _, ps) <- prod_info 
>    , p <- ps ]


%-----------------------------------------------------------------------------
Create default decoding functions

Idea is that sem rules are stored as functions in the AbsSyn names, and 
only unpacked when needed. Using classes here to manage the unpacking. 

> -- mkDecodeUtils :: DecodeOption -> [(String, String, [Int])] -> String
> mkDecodeUtils (TreeDecode,filter_opt,_) seminfo
>  = unlines $ concatMap mk_inst ty_cs
>    where
>	ty_cs = [ (ty, [ (c_name, mask)
>	               | (ty2, c_name, mask, j_vs) <- seminfo
>	               , ty2 == ty
>	               ])
>	        | ty <- nub [ ty | (ty,_,_,_) <- seminfo ]
>	        ]		-- group by same type

>	mk_inst (ty, cs_vs)
>	 = ("instance TreeDecode (" ++ ty ++ ") where ")
>	 : [ "\tdecode_b f (Branch (" ++ c_name ++ " s) (" ++ var_pat ++ ")) = "
>                  ++ cross_prod "[s]" (nodes filter_opt)
>	   | (c_name, vs) <- cs_vs 
>	   , let vars = [ "b_" ++ show n | n <- var_range filter_opt vs ]
>	   , let var_pat = foldr (\l r -> l ++ ":" ++ r) "_" vars
>	   , let nodes NoFiltering  = [ vars !! n | n <- vs ]
>	         nodes UseFiltering = vars 
>	   ]

>	var_range _            [] = []
>	var_range NoFiltering  vs = [0 .. maximum vs ]
>	var_range UseFiltering vs = [0 .. length vs - 1]

>	cross_prod s [] = s
>	cross_prod s (a:as) 
>	 = cross_prod ("(cross_fn " ++ s ++ " $ decode f " ++ a ++ ")") as


> mkDecodeUtils (LabelDecode,_,_) seminfo
>  = unlines $ concatMap mk_inst ty_cs
>    where
>	ty_cs = [ (ty, [ (c_name, mask)
>	               | (ty2, c_name, mask, _) <- seminfo
>	               , ty2 == ty
>	               ])
>	        | ty <- nub [ ty | (ty,_,_,_) <- seminfo ]
>	        ]		-- group by same type

>	mk_inst (ty, cns)
>	 = ("instance LabelDecode (" ++ ty ++ ") where ")
>	 : [ "\tunpack (" ++ c_name ++ " s) = s"
>	   | (c_name, mask) <- cns ]


%-----------------------------------------------------------------------------
Util Functions

---
remove Happy-generated start symbols.

> user_non_terminals :: Grammar -> [Name]
> user_non_terminals g
>  = non_terminals g \\ start_productions g

> start_productions :: Grammar -> [Name]
> start_productions g = [ s | (_,s,_) <- starts g ]


---

> mkHappyVar n = showString "happy_var_" . shows n


