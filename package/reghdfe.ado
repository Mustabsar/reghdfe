*! version 1.4.1 02mar2015
*! By Sergio Correia (sergio.correia@duke.edu)
* (built from multiple source files using build.py)
program define reghdfe
	local version `=clip(`c(version)', 11.2, 13.1)' // 11.2 minimum, 13+ preferred
	qui version `version'

	if replay() {
		if (`"`e(cmd)'"'!="reghdfe") error 301
		Replay `0'
	}
	else {
		* Estimate, and then clean up Mata in case of failure
		mata: st_global("reghdfe_pwd",pwd())
		cap noi Estimate `0'
		if (_rc) {
			local rc = _rc
			reghdfe_absorb, step(stop)
			exit `rc'
		}
	}
end


mata:
mata set matastrict on

// -------------------------------------------------------------------------------------------------
// Fix nonpositive VCV; called from Wrapper_mwc.ado 
// -------------------------------------------------------------------------------------------------
void function fix_psd(string scalar Vname) {
	real matrix V, U, lambda

	V = st_matrix(Vname)
	if (!issymmetric(V)) exit(error(505))
	symeigensystem(V, U=., lambda=.)
	st_local("eigenfix", "0")
	if (min(lambda)<0) {
		lambda = lambda :* (lambda :>= 0)
		// V = U * diag(lambda) * U'
		V = quadcross(U', lambda, U')
		st_local("eigenfix", "1")
	}
	st_replacematrix(Vname, V)
}

end


// -------------------------------------------------------------------------------------------------
// Transform data and run the regression
// -------------------------------------------------------------------------------------------------
program define Estimate, eclass

/* Notation of created variables
	__FE1__        		Fixed effect categories
	__Z1__         		Fixed effect coefficients (estimates)
	__clustervar1__		Categories for the clusters that had to be generated
	__W1__         		AvgE transformed variables (avg of depvar by category)
*/

// PART I - PREPARE DATASET FOR REGRESSION

* 1) Parse main options
	reghdfe_absorb, step(stop) // clean Mata leftovers before running -Parse-
	Parse `0' // save all arguments into locals (verbose>=3 shows them)
	local sets depvar indepvars endogvars instruments // depvar MUST be first

* 2) Parse identifiers (absorb variables, avge, clustervar)
	reghdfe_absorb, step(start) absorb(`absorb') over(`over') avge(`avge') clustervars(`clustervars') weight(`weight') weightvar(`weightvar')
	* Note: In this step, it doesn't matter if the weight is FW or AW
	local N_hdfe = r(N_hdfe)
	local N_avge = r(N_avge)
	local RAW_N = c(N)
	local RAW_K = c(k)
	local absorb_keepvars = r(keepvars) // Vars used in hdfe,avge,cluster
	
	qui de, simple
	local old_mem = string(r(width) * r(N)  / 2^20, "%6.2f") // This is just for debugging; measured in MBs

* 3) Preserve
if ("`usecache'"!="") {
	local uid __uid__
}
else {
	tempvar uid
	local uid_type = cond(`RAW_N'>c(maxlong), "double", "long")
	gen `uid_type' `uid' = _n // Useful for later merges
	la var `uid' "[UID]" // So I can recognize it in -describe-
}

	if (`savingcache') {
		cap drop __uid__
		rename `uid' __uid__
		local uid __uid__
		local handshake = int(uniform()*1e8)
		char __uid__[handshake] `handshake'
		char __uid__[tolerance] `tolerance'
		char __uid__[maxiterations] `maxiterations'
	}

	preserve
	Debug, msg("(dataset preserved)") level(2)

* 4) Drop unused variables
	if ("`vceextra'"!="") local tsvars `panelvar' `timevar' // We need to keep these when using an autoco-robust VCE
	local exp "= `weightvar'"
	marksample touse, novar // Uses -if- , -in- ; -weight-? and -exp- ; can't drop any var until this
	keep `uid' `touse' `timevar' `panelvar' `absorb_keepvars' `basevars' `over' `weightvar' `tsvars'

* 5) Expand factor and time-series variables (this *must* happen before reghdfe precompute is called!)
	local expandedvars
	foreach set of local sets {
		local varlist ``set''
		if ("`varlist'"=="") continue
		local original_`set' `varlist'
		* the -if- prevents creating dummies for categories that have been excluded
		ExpandFactorVariables `varlist' if `touse', setname(`set')
		local `set' "`r(varlist)'"
		local expandedvars `expandedvars' ``set''
	} 

* 6) Drop unused basevars and tsset vars (usually no longer needed)
	keep `uid' `touse' `absorb_keepvars' `expandedvars' `over' `weightvar' `tsvars'

* 7) Drop all observations with missing values (before creating the FE ids!)
	markout `touse' `expandedvars'
	markout `touse' `expandedvars' `absorb_keepvars'
	qui keep if `touse'
	Assert c(N)>0, rc(2000)
	drop `touse'
	if ("`over'"!="" & `savingcache') qui levelsof `over', local(levels_over)

* 8) Fill Mata structures, create FE identifiers, avge vars and clustervars if needed
	reghdfe_absorb, step(precompute) keep(`uid' `expandedvars' `tsvars') depvar("`depvar'") `excludeself' tsvars(`tsvars')
	Debug, level(2) msg("(dataset compacted: observations " as result "`RAW_N' -> `c(N)'" as text " ; variables " as result "`RAW_K' -> `c(k)'" as text ")")
	local avgevars = cond("`avge'"=="", "", "__W*__")
	local vars `expandedvars' `avgevars'

	* qui compress `expandedvars' // will recast to -double- later on
	qui de, simple
	local new_mem = string(r(width) * r(N) / 2^20, "%6.2f")
	Debug, level(2) msg("(dataset compacted, c(memory): " as result "`old_mem'" as text "M -> " as result "`new_mem'" as text "M)")

* 9) Check that weights have acceptable values
if ("`weightvar'"!="") {
	local require_integer = ("`weight'"=="fweight")
	local num_type = cond(`require_integer', "integers", "reals")

	local basenote "weight -`weightvar'- can only contain strictly positive `num_type', but"
	qui cou if `weightvar'<0
	Assert (`r(N)'==0), msg("`basenote' `r(N)' negative values were found!")
	qui cou if `weightvar'==0
	Assert (`r(N)'==0), msg("`basenote' `r(N)' zero values were found!")
	qui cou if `weightvar'>=.
	Assert (`r(N)'==0), msg("`basenote' `r(N)' missing values were found!")
	if (`require_integer') {
		qui cou if mod(`weightvar',1)
		Assert (`r(N)'==0), msg("`basenote' `r(N)' non-integer values were found!")
	}
}

* 10) Save the statistics we need before transforming the variables
if (`savingcache') {
	cap drop __FE*__
	cap drop __clustervar*__
}
else {
	* Compute TSS of untransformed depvar
	local tmpweightexp = subinstr("`weightexp'", "[pweight=", "[aweight=", 1)
	qui su `depvar' `tmpweightexp' // BUGBUG: Is this correct?!
	local tss = r(Var)*(r(N)-1)
	assert `tss'<.

* 11) Calculate the degrees of freedom lost due to the FEs
	if ("`group'"!="") {
		tempfile groupdta
		local opt group(`group') groupdta(`groupdta') uid(`uid')
	}
	EstimateDoF, dofadjustments(`dofadjustments') `opt'
	local kk = r(kk) // FEs that were not found to be redundant (= total FEs - redundant FEs)
	local M = r(M) // FEs found to be redundant
	local saved_group = r(saved_group)
	local M_due_to_nested = r(M_due_to_nested)

	Assert `kk'<.
	Assert `M'>=0 & `M'<.
	assert inlist(`saved_group', 0, 1)

	forv g=1/`N_hdfe' {
		local M`g' = r(M`g')
		local K`g' = r(K`g')
		local M`g'_exact = r(M`g'_exact)

		assert inlist(`M`g'_exact',0,1) // 1 or 0 whether M`g' was calculated exactly or not
		assert `M`g''<. & `K`g''<.
		assert `M`g''>=0 & `K`g''>=0
		assert inlist(r(drop`g'), 0, 1)

		* Drop IDs for the absorbed FEs (except if its the clustervar)
		* Useful b/c regr. w/cluster takes a lot of memory
		if (r(drop`g')==1) drop __FE`g'__
	}

	if (`num_clusters'>0) {
		mata: mata: st_local("temp_clustervars", invtokens(clustervars))
		local vceoption : subinstr local vceoption "<CLUSTERVARS>" "`temp_clustervars'"
	}

}

* 12) Save untransformed data.
*	This allows us to:
*	i) do nested ftests for the FEs,
*	ii) recover the FEs, compute their correlations with xb, check that FE==1

	* We can avoid this if i) nested=check=0 ii) targets={} iii) fast=1
	mata: st_local("any_target_avge", strofreal(any(avge_target :!= "")) ) // saving avge?
	local any_target_hdfe 0 // saving hdfe?
	forv g=1/`N_hdfe' {
		reghdfe_absorb, fe2local(`g')
		if (!`is_bivariate' | `is_mock') local hdfe_cvar`g' `cvars'
		// If it's the intercept part of the bivariate absorbed effect, don't add the cvar!
		local hdfe_target`g' `target'
		if ("`target'"!="") local any_target_hdfe 1
	}

	if (`fast') {
		if (`nested' | `check' | `any_target_hdfe' | `any_target_avge' | "`group'"!="" | `cores'>1) {
			Debug, msg(as text "(option {it:fast} not compatible with other options; disabled)") level(0) // {opt ..} is too boldy
			local fast 0
		}
		else {
			Debug, msg("(option {opt fast} specified; will not save e(sample) or compute correlations)")
		}
	}

	if (!`fast') {
		sort `uid'
		tempfile original_vars
		qui save "`original_vars'"
		if (`cores'>1) local parallel_opt `" filename("`original_vars'") uid(`uid') cores(`cores') "'
		Debug, msg("(untransformed dataset saved)") level(2)
	}

* 13) (optional) Compute R2/RSS to run nested Ftests on the FEs
	* a) Compute R2 of regression without FE, to build the joint FTest for all the FEs
	* b) Also, compute RSS of regressions with less FEs so we can run nested FTests on the FEs
	if ("`model'"=="ols" & !`savingcache') {
		qui _regress `vars' `weightexp', noheader notable
		local r2c = e(r2)

		if (`nested') {
			local rss0 = e(rss)
			local subZs
			forv g=1/`=`N_hdfe'-1' {
				Debug, msg("(computing nested model w/`g' FEs)")
				reghdfe_absorb, step(demean) varlist(`vars') `maximize_options' num_fe(`g') `parallel_opt'
				qui _regress `vars' `weightexp', noheader notable
				local rss`g' = e(rss)
				qui use "`original_vars'", clear // Back to untransformed dataset
			}
		}
	}

	* Get normalized string of the absvars (i.e. turn -> i.turn)
	local original_absvars
	forv g=1/`N_hdfe' {
		reghdfe_absorb, fe2local(`g')
		local original_absvars `original_absvars'  `varlabel'
	}

* 14) Compute residuals for all variables including the AvgEs (overwrites vars!)
	qui ds `vars'
	local NUM_VARS : word count `r(varlist)'
	Debug, msg("(computing residuals for `NUM_VARS' variables)")
	Debug, msg(" - tolerance = `tolerance'")
	Debug, msg(" - max. iter = `maxiterations'")
	if ("`usecache'"=="") {
		reghdfe_absorb, step(demean) varlist(`vars') `maximize_options' `parallel_opt'
	}
	else {
		Debug, msg("(using cache data)")
		drop `vars'
		local handshake_master : char __uid__[handshake]
		char __uid__[handshake]
		// An error in the merge most likely means different # of obs due to missing values in a group but not in other
		// try with if !missing(__uid__) // TODO: Auto-add this by default?
		// TODO: Make this fool-proof when using -over-
		if ("`over'"!="") local using using // This is dangerous
		sort __uid__ // The user may have changed the sort order of the master data
		qui merge 1:1 __uid__ using "`usecache'", keepusing(`vars') assert(match master `using') keep(master match) nolabel sorted
		qui cou if _merge!=3
		if (r(N)>0) {
			Debug, level(0) msg(as error "Warning: the cache has `r(N)' less observations than the master data" _n as text ///
				" - This is possibly because, when created, it included variables that were missing in cases where the current ones are not." _n ///
				" - It may or may not be an error depending on your objective.")
		}
		qui drop if _merge!=3
		drop _merge

		local handshake_using : char __uid__[handshake]
		local tolerance_using : char __uid__[tolerance]
		local maxiterations_using : char __uid__[maxiterations]
		Assert (`handshake_master'==`handshake_using'), msg("using dataset does not have the same __uid__")
		Assert abs(`tolerance'-`tolerance_using')<epsdouble(), msg("using dataset not computed with the same tolerance (`tolerance_using')")
		Assert (`maxiterations'==`maxiterations_using'), msg("using dataset not computed with the same maxiterations (`maxiterations_using')")

		local absvar_master `original_absvars'
		local absvar_using : char __uid__[absvars_key]
		Assert ("`absvar_master'"=="`absvar_using'"), msg("using dataset not created with the same absvars")
		char __uid__[absvars_key]
	}

if (`savingcache') {
	Debug, msg("(saving cache and exiting)")
	char __uid__[absvars_key] `original_absvars'
	sort __uid__
	save "`savecache'", replace
	if ("`levels_over'"!="") ereturn local levels_over = "`levels_over'"
	exit
}

// PART II - REGRESSION

* Cleanup
	ereturn clear

* Add back constant
	if (`addconstant') {
		Debug, level(3) msg(_n "adding back constant to regression")
		AddConstant `depvar' `indepvars' `avgevars' `endogvars' `instruments'
	}

* Regress
	Debug, level(2) msg("(running regresion: `model'.`ivsuite')")
	local avge = cond(`N_avge'>0, "__W*__", "")
	local options
	local option_list ///
		depvar indepvars endogvars instruments avgevars ///
		original_depvar original_indepvars original_endogvars ///
		original_instruments original_absvars avge_targets ///
		vceoption vcetype vcesuite ///
		kk suboptions showraw first weightexp ///
		addconstant // tells -regress- to hide _cons
	foreach opt of local option_list {
		if ("``opt''"!="") local options `options' `opt'(``opt'')
	}

	* Five wrappers in total, two for iv (ivreg2, ivregress), three for ols (regress, avar, mwc)
	local wrapper "Wrapper_`subcmd'" // regress ivreg2 ivregress
	if ("`subcmd'"=="regress" & "`vcesuite'"=="avar") local wrapper "Wrapper_avar"
	if ("`subcmd'"=="regress" & "`vcesuite'"=="mwc") local wrapper "Wrapper_mwc"
	Debug, level(3) msg(_n "call to wrapper:" _n as result "`wrapper', `options'")
	`wrapper', `options'
	local subpredict = e(predict) // used to recover the FEs

	if ("`weightvar'"!="") {
		qui su `weightvar', mean
		local sumweights = r(sum)
	}

// PART III - RECOVER FEs AND SAVE RESULTS 

if (`fast') {
	* Copy pasted from below
	Debug, level(3) msg("(avoiding -use- of temporary dataset")
	tempname b
	matrix `b' = e(b)
	local backup_colnames : colnames `b'
	FixVarnames `backup_colnames'
	local newnames "`r(newnames)'"
	local prettynames "`r(prettynames)'"
	matrix colnames `b' = `newnames'

	clear // can comment out after debugging
}
else {

* 1) Restore untransformed dataset
	qui use "`original_vars'", clear

* 2) Recover the FEs
	* Predict will get (e+d) from the equation y=xb+d+e
	tempvar resid_d
	local score = cond(inlist("`vcesuite'", "avar", "mwc"), "score", "resid")
	`subpredict' double `resid_d', `score' // Auto-selects the program based on the estimation method
	Debug, level(2) msg("(loaded untransformed variables, predicted residuals)")

	* Absorb the residuals to obtain the FEs (i.e. run a regression on just the resids)
	Debug, level(2) tic(31)
	reghdfe_absorb, step(demean) varlist(`resid_d') `maximize_options' save_fe(1)
	Debug, level(2) toc(31) msg("mata:make_residual on final model took")
	drop `resid_d'

* 3) Compute corr(FE,xb) (do before rescaling by cvar or deleting)
	if ("`model'"=="ols") {
		tempvar xb
		_predict double `xb', xb // -predict- overwrites sreturn, use _predict if needed
		forv g=1/`N_hdfe' { 
			qui corr `xb' __Z`g'__
			local corr`g' = r(rho)
		}
		drop `xb'
	}

* 4) Replace tempnames in the coefs table
	* (e.g. __00001 -> L.somevar)
	* (this needs to be AFTER predict but before deleting FEs and AvgEs)
	tempname b
	matrix `b' = e(b)
	local backup_colnames : colnames `b'
	FixVarnames `backup_colnames'
	local newnames "`r(newnames)'"
	local prettynames "`r(prettynames)'"
	matrix colnames `b' = `newnames'

* 5) Save FEs w/proper name, format
	reghdfe_absorb, step(save) original_depvar(`original_depvar')
	local keepvars `r(keepvars)'
	if ("`keepvars'"!="") format `fe_format' `keepvars'

* 6) Save AvgEs
	forv g=1/`N_avge' {
		local var __W`g'__
		local target : char `var'[target]
		if ("`target'"!="") {
			rename `var' `target'
			local avge_target`g' `target' // Used by -predict-
			local keepvars `keepvars' `target'
		}
	}

	if ("`keepvars'"!="") format `fe_format' `keepvars' // The format of depvar, saved by -Parse-

* 7) Save dataset with FEs and e(sample)
	keep `uid' `keepvars'
	tempfile output
	qui save "`output'"
} // fast

* 8) Restore original dataset and merge
	restore // Restore user-provided dataset
	if (!`fast') {
		// `saved_group' was created by EstimateDoF.ado
		if (!`saved_group')  local groupdta
		SafeMerge, uid(`uid') file("`output'") groupdta("`groupdta'")
		*cap tsset, noquery // we changed -sortby- when we merged (even if we didn't really resort)
	}

// PART IV - ERETURN OUTPUT

	if (`c(version)'>=12) local hidden hidden // ereturn hidden requires v12+

* Ereturns common to all commands
	ereturn local cmd = "reghdfe"
	ereturn local subcmd = "`subcmd'"
	ereturn local cmdline `"`cmdline'"'
	if ("`e(model)'"!="" & "`e(model)'"!="`model'") di as error "`e(model) was <`e(model)'>" // ?
	ereturn local model = "`model'"
	ereturn local dofadjustments = "`dofadjustments'"
	ereturn local title = "HDFE " + e(title)
	ereturn local subtitle =  "Absorbing `N_hdfe' HDFE " + plural(`N_hdfe', "indicator")
	ereturn local predict = "reghdfe_p"
	ereturn local estat_cmd = "reghdfe_estat"
	ereturn local footnote = "reghdfe_footnote"
	ereturn local absvars = "`original_absvars'"
	ereturn local vcesuite = "`vcesuite'"
	ereturn `hidden' local diopts = "`diopts'"

	if ("`e(clustvar)'"!="") {
		mata: st_local("clustvar", invtokens(clustervars_original))
		ereturn local clustvar "`clustvar'"
		ereturn scalar N_clustervars = `num_clusters'
	}

	* Besides each cmd's naming style (e.g. exogr, exexog, etc.) keep one common one
	foreach cat in depvar indepvars endogvars instruments {
		local vars ``cat''
		if ("`vars'"=="") continue
		ereturn local `cat' "`original_`cat''"
	}
	ereturn local avgevars "`avge'" // bugbug?

	ereturn `hidden' local subpredict = "`subpredict'"
	ereturn `hidden' local prettynames "`prettynames'"
	forv g=1/`N_avge' {
		ereturn `hidden' local avge_target`g' "`avge_target`g''" // Used by -predict-
	}

	* Stata uses e(vcetype) for the SE column headers
	* In the default option, leave it empty.
	* In the cluster and robust options, set it as "Robust"
	ereturn local vcetype = proper("`vcetype'") //
	if (e(vcetype)=="Cluster") ereturn local vcetype = "Robust"
	if (e(vcetype)=="Unadjusted") ereturn local vcetype
	if ("`e(vce)'"=="." | "`e(vce)'"=="") ereturn local vce = "`vcetype'" // +-+-
	Assert inlist("`e(vcetype)'", "", "Robust", "Jackknife", "Bootstrap")
	
	* Clear results that are wrong
	ereturn local ll
	ereturn local ll_0

	ereturn scalar N_hdfe = `N_hdfe'
	if ("`N_avge'"!="") ereturn scalar N_avge = `N_avge'

* Absorbed-specific returns
	ereturn scalar mobility = `M'
	ereturn scalar df_a = `kk'
	forv g=1/`N_hdfe' {
		ereturn scalar M`g' = `M`g''
		ereturn scalar K`g' = `K`g''
		ereturn `hidden' scalar M`g'_exact = `M`g'_exact' // 1 or 0 whether M`g' was calculated exactly or not
		ereturn `hidden' local corr`g' = "`corr`g''" //  cond("`corr`g''"=="", ., "`corr`g''")
		ereturn `hidden' local hdfe_target`g' = "`hdfe_target`g''"
		ereturn `hidden' local hdfe_cvar`g' = "`hdfe_cvar`g''"
	}

	Assert e(df_r)<. , msg("e(df_r) is missing")
	ereturn scalar tss = `tss'
	ereturn scalar mss = e(tss) - e(rss)
	ereturn scalar r2 = 1 - e(rss) / `tss'

	* ivreg2 uses e(r2c) and e(r2u) for centered/uncetered R2; overwrite first and discard second
	if (e(r2c)!=.) {
		ereturn scalar r2c = e(r2)
		ereturn scalar r2u = .
	}

	* Computing Adj R2 with custered SEs is tricky because it doesn't use the adjusted inputs:
	* 1) It uses N instead of N_clust
	* 2) For the DoFs, it uses N - Parameters instead of N_clust-1
	* 3) Further, to compute the parameters, it includes those nested within clusters
	
	* Note that this adjustment is NOT PERFECT because we won't compute the mobility groups just for improving the r2a
	* (when a FE is nested within a cluster, we don't need to compute mobilty groups; but to get the same R2a as other estimators we may want to do it)
	* Instead, you can set by hand the dof() argument and remove -cluster- from the list

	if ("`model'"=="ols" & `num_clusters'>0) Assert e(unclustered_df_r)<., msg("wtf-`vcesuite'")
	local used_df_r = cond(e(unclustered_df_r)<., e(unclustered_df_r), e(df_r)) - `M_due_to_nested'
	ereturn scalar r2_a = 1 - (e(rss)/`used_df_r') / (`tss' / (e(N)-1) )

	ereturn scalar rmse = sqrt( e(rss) / `used_df_r' )
	if (e(N_clust)<.) ereturn scalar df_r = e(N_clust) - 1

	if ("`weightvar'"!="") ereturn scalar sumweights = `sumweights'

	if ("`model'"=="ols" & inlist("`vcetype'", "unadjusted", "ols")) {
		ereturn scalar F_absorb = (e(r2)-`r2c') / (1-e(r2)) * e(df_r) / `kk'
		if (`nested') {
			local rss`N_hdfe' = e(rss)
			local temp_dof = e(N) - 1 - e(df_m) // What if there are absorbed collinear with the other RHS vars?
			local j 0
			ereturn `hidden' scalar rss0 = `rss0'
			forv g=1/`N_hdfe' {
				local temp_dof = `temp_dof' - e(K`g') + e(M`g')
				*di in red "g=`g' RSS=`rss`g'' and was `rss`j''.  dof=`temp_dof'"
				ereturn `hidden' scalar rss`g' = `rss`g''
				ereturn `hidden' scalar df_a`g' = e(K`g') - e(M`g')
				ereturn scalar F_absorb`g' = (`rss`j''-`rss`g'') / `rss`g'' * `temp_dof' / e(df_a`g')
				ereturn `hidden' scalar df_r`g' = `temp_dof'
				local j `g'
			}   
		}
	}

	// There is a big assumption here, that the number of other parameters does not increase asymptotically
	// BUGBUG: We should allow the option to indicate what parameters do increase asympt.
	// BUGBUG; xtreg does this: est scalar df_r = min(`df_r':=N-1-K, `df_cl') why was that?

	if ("`savefirst'"!="") ereturn `hidden' scalar savefirst = `savefirst'

	* We have to replace -unadjusted- or else subsequent calls to -suest- will fail
	if (e(vce)=="unadjusted") ereturn local vce = "ols"

* Show table and clean up
	ereturn repost b=`b', rename // why here???
	Replay
	reghdfe_absorb, step(stop)

end

* The idea of this program is to keep the sort order when doing the merges
program define SafeMerge, eclass sortpreserve
syntax, uid(varname numeric) file(string) [groupdta(string)]
	* Merging gives us e(sample) and the FEs / AvgEs
	tempvar merge
	merge 1:1 `uid' using "`file'", assert(master match) nolabel nonotes noreport gen(`merge')
	
	* Add e(sample) from _merge
	tempvar sample
	gen byte `sample' = (`merge'==3)
	la var `sample' "[HDFE Sample]"
	ereturn repost , esample(`sample')
	drop `merge'

	* Add mobility group
	if ("`groupdta'"!="") merge 1:1 `uid' using "`groupdta'", assert(master match) nogen nolabel nonotes noreport sorted
end


	
// -------------------------------------------------------------
// Parsing and basic sanity checks for REGHDFE.ado
// -------------------------------------------------------------
// depvar: dependent variable
// indepvars: included exogenous regressors
// endogvars: included endogenous regressors
// instruments: excluded exogenous regressors
program define Parse

* Remove extra spacing from cmdline (just for aesthetics, run before syntax)
	cap syntax anything(name=indepvars) [if] [in] [fweight aweight pweight/] , SAVEcache(string) [*]
	local savingcache = (`=_rc'==0)

if (`savingcache') {

	* Disable these options
	local fast
	local nested

	syntax anything(name=indepvars) [if] [in] [fweight aweight pweight/] , ///
		Absorb(string) SAVEcache(string) ///
		[Verbose(integer 0) CHECK TOLerance(real 1e-7) MAXITerations(integer 1000) noACCELerate ///
		bad_loop_threshold(integer 1) stuck_threshold(real 5e-3) pause_length(integer 20) ///
		accel_freq(integer 3) accel_start(integer 6) /// Advanced optimization options
		CORES(integer 1) OVER(varname numeric)]

	cap conf file "`savecache'.dta"
	if (`=_rc'!=0) {
		cap conf new file "`savecache'.dta"
		Assert (`=_rc'==0), msg("reghdfe will not be able to save `savecache'.dta")
	}

}
else {
	mata: st_local("cmdline", stritrim(`"reghdfe `0'"') )
	ereturn clear // Clear previous results and drops e(sample)
	syntax anything(id="varlist" name=0 equalok) [if] [in] ///
		[fweight aweight pweight/] , ///
		Absorb(string) ///
		[VCE(string)] ///
		[DOFadjustments(string) GROUP(name)] ///
		[avge(string) EXCLUDESELF] ///
		[Verbose(integer 0) CHECK NESTED FAST] ///
		[TOLerance(real 1e-7) MAXITerations(integer 1000) noACCELerate] /// See reghdfe_absorb.Annihilate
		[noTRACK] /// Not used here but in -Track-
		[IVsuite(string) SAVEFIRST FIRST SHOWRAW] /// ESTimator(string)
		[SMALL Hascons TSSCONS] /// ignored options
		[gmm2s liml kiefer cue] ///
		[SUBOPTions(string)] /// Options to be passed to the estimation command (e.g . to regress)
		[bad_loop_threshold(integer 1) stuck_threshold(real 5e-3) pause_length(integer 20) accel_freq(integer 3) accel_start(integer 6)] /// Advanced optimization options
		[CORES(integer 1)] [USEcache(string)] [OVER(varname numeric)] ///
		[noCONstant] /// Disable adding back the intercept (mandatory with -ivreg2-)
		[*] // For display options
}

* Weight
* We'll have -weight- (fweight|aweight|pweight), -weightvar-, -exp-, and -weightexp-
	if ("`weight'"!="") {
		local weightvar `exp'
		conf var `weightvar' // just allow simple weights
		local weightexp [`weight'=`weightvar']
		local backupweight `weight'
	}

* Cache options
	if ("`usecache'"!="") {
		conf file "`usecache'.dta"
		conf var __uid__
		Assert ("`avge'"==""), msg("option -avge- not allowed with -usecache-")
		Assert ("`avge'"==""), msg("option -nested- not allowed with -usecache-")
	}

* Save locals that will be overwritten by later calls to -syntax-
	local ifopt `if'
	local inopt `in'

* Coef Table Options
if (!`savingcache') {
	_get_diopts diopts options, `options'
	Assert `"`options'"'=="", msg(`"invalid options: `options'"')
	if ("`hascons'`tsscons'"!="") di in ye "(option `hascons'`tsscons' ignored)"
}

* Over
	if ("`over'"!="") {
		unab over : `over', max(1)
		Assert ("`usecache'"!="" | "`savecache'"!=""), msg("-over- needs to be used together with either -usecache- or -savecache-")
	}

* Verbose
	assert inlist(`verbose', 0, 1, 2, 3, 4) // 3 and 4 are developer options
	mata: VERBOSE = `verbose' // Ugly hack to avoid using a -global-

* Show raw output of called subcommand (e.g. ivreg2)
	local showraw = ("`showraw'"!="")

* tsset variables, if any
	cap conf var `_dta[_TStvar]'
	if (!_rc) local timevar `_dta[_TStvar]'
	cap conf var `_dta[_TSpanel]'
	if (!_rc) local panelvar `_dta[_TSpanel]'

* Model settings
if (!`savingcache') {

	// local model = cond(strpos(`"`0'"', " ("), "iv", "ols") // Fails with long strs in stata 12<
	local model ols
	foreach _ of local 0 {
		if (substr(`"`_'"', 1, 1)=="(") {
			local model iv
			continue, break
		}
	}
	

	* For this, _iv_parse would have been useful, although I don't want to do factor expansions when parsing
	if ("`model'"=="iv") {
		* get part before parentheses
		local wrongparens 1
		while (`wrongparens') {
			gettoken tmp 0 : 0 ,p("(")
			local left `left'`tmp'
			* Avoid matching the parens of e.g. L(-1/2) and L.(var1 var2)
			* Using Mata to avoid regexm() and trim() space limitations
			mata: st_local("tmp1", subinstr("`0'", " ", "") ) // wrong parens if ( and then a number
			mata: st_local("tmp2", substr(strtrim("`left'"), -1) ) // wrong parens if dot
			local wrongparens = regexm("`tmp1'", "^\([0-9-]") | ("`tmp2'"==".")
			if (`wrongparens') {
				gettoken tmp 0 : 0 ,p(")")
				local left `left'`tmp'
			}
		}

		* get part in parentheses
		gettoken right 0 : 0 ,bind match(parens)
		Assert trim(`"`0'"')=="" , msg("error: remaining argument: `0'")

		* now parse part in parentheses
		gettoken endogvars instruments : right ,p("=")
		gettoken equalsign instruments : instruments ,p("=")

		Assert "`endogvars'"!="", msg("iv: endogvars required")
		local 0 `endogvars'
		syntax varlist(fv ts numeric)

		Assert "`instruments'"!="", msg("iv: instruments required")
		local 0 `instruments'
		syntax varlist(fv ts numeric)
		
		local 0 `left' // So OLS part can handle it
		Assert "`endogvars'`instruments'"!=""
		
		if ("`ivsuite'"=="") local ivsuite ivreg2
		Assert inlist("`ivsuite'","ivreg2","ivregress") , msg("error: wrong IV routine (`ivsuite'), valid options are -ivreg2- and -ivregress-")
		cap findfile `ivsuite'.ado
		Assert !_rc , msg("error: -`ivsuite'- not installed, please run {stata ssc install `ivsuite'} or change the option -ivsuite-")
	}

* OLS varlist
	syntax varlist(fv ts numeric)
	gettoken depvar indepvars : 0
	_fv_check_depvar `depvar'

* Extract format of depvar so we can format FEs like this
	fvrevar `depvar', list
	local fe_format : format `r(varlist)' // The format of the FEs and AvgEs that will be saved

* Variables shouldn't be repeated
* This is not perfect (e.g. doesn't deal with "x1-x10") but still helpful
	local allvars `depvar' `indepvars' `endogvars' `instruments'
	local dupvars : list dups allvars
	Assert "`dupvars'"=="", msg("error: there are repeated variables: <`dupvars'>")

	Debug, msg(_n " {title:REGHDFE} Verbose level = `verbose'")
	*Debug, msg("{hline 64}")

* Add back constants (place this *after* we define `model')
	local addconstant = ("`constant'"!="noconstant") & !("`model'"=="iv" & "`ivsuite'"=="ivreg2")

* Parse VCE options:
	* Note: bw=1 means just do HC instead of HAC
	local 0 `vce'
	syntax [anything(id="VCE type")] , [bw(integer 1)] [kernel(string)] [dkraay(integer 1)] [kiefer] [suite(string)]
	if ("`anything'"=="") local anything unadjusted
	Assert `bw'>0, msg("VCE bandwidth must be a positive integer")
	gettoken vcetype clustervars : anything
	* Expand variable abbreviations; but this adds unwanted i. prefixes
	if ("`clustervars'"!="") {
		fvunab clustervars : `clustervars'
		local clustervars : subinstr local clustervars "i." "", all
	}

	* vcetype abbreviations:
	if (substr("`vcetype'",1,3)=="ols") local vcetype unadjusted
	if (substr("`vcetype'",1,2)=="un") local vcetype unadjusted
	if (substr("`vcetype'",1,1)=="r") local vcetype robust
	if (substr("`vcetype'",1,2)=="cl") local vcetype cluster
	if ("`vcetype'"=="conventional") local vcetype unadjusted // Conventional is the name given in e.g. xtreg
	Assert strpos("`vcetype'",",")==0, msg("Unexpected contents of VCE: <`vcetype'> has a comma")

	* Sanity checks on vcetype
	if ("`vcetype'"=="" & "`backupweight'"=="pweight") local vcetype robust
	Assert !("`vcetype'"=="unadjusted" & "`backupweight'"=="pweight"), msg("pweights do not work with unadjusted errors, use a different vce()")
	if ("`vcetype'"=="") local vcetype unadjusted
	Assert inlist("`vcetype'", "unadjusted", "robust", "cluster"), msg("VCE type not supported: `vcetype'")

	* Cluster vars
	local num_clusters : word count `clustervars'
	Assert inlist( (`num_clusters'>0) + ("`vcetype'"=="cluster") , 0 , 2), msg("Can't specify cluster without clustervars and viceversa") // XOR

	* VCE Suite
	local vcesuite `suite'
	if ("`vcesuite'"=="") local vcesuite default
	if ("`vcesuite'"=="default") {
		if (`bw'>1 | `dkraay'>1 | "`kiefer'"!="" | "`kernel'"!="") {
			local vcesuite avar
		}
		else if (`num_clusters'>1) {
			local vcesuite mwc
		}
	}
	
	Assert inlist("`vcesuite'", "default", "mwc", "avar"), msg("Wrong vce suite: `vcesuite'")
	if (inlist("`vcesuite'", "avar", "mwc")) local addconstant 0 // The constant messes up the VCV

	if ("`vcesuite'"=="mwc") {
		cap findfile tuples.ado
		Assert !_rc , msg("error: -tuples- not installed, please run {stata ssc install tuples} to estimate multi-way clusters.")
	}
	
	if ("`vcesuite'"=="avar") {
		cap findfile `vcesuite'.ado
		Assert !_rc , msg("error: -`vcesuite'- not installed, please run {stata ssc install `vcesuite'} or change the option -vcesuite-")
	}

	* Some combinations are not coded
	Assert !("`ivsuite'"=="ivregress" & (`num_clusters'>1 | `bw'>1 | `dkraay'>1 | "`kiefer'"!="" | "`kernel'"!="") ), msg("option vce(`vce') incompatible with ivregress")
	Assert !("`ivsuite'"=="ivreg2" & (`num_clusters'>2) ), msg("ivreg2 doesn't allow more than two cluster variables")
	Assert !("`model'"=="ols" & "`vcesuite'"=="avar" & (`num_clusters'>2) ), msg("avar doesn't allow more than two cluster variables")
	Assert !("`model'"=="ols" & "`vcesuite'"=="default" & (`bw'>1 | `dkraay'>1 | "`kiefer'"!="" | "`kernel'"!="") ), msg("to use those vce options you need to use -avar- as the vce suite")

	if (`num_clusters'>0) local temp_clustervars " <CLUSTERVARS>"
	if (`bw'>1 | "`kernel'"!="") local vceextra `vceextra' bw(`bw') 
	if (`dkraay'>1) local vceextra `vceextra' dkraay(`dkraay') 
	if ("`kiefer'"!="") local vceextra `vceextra' kiefer 
	if ("`kernel'"!="") local vceextra `vceextra' kernel(`kernel')
	if ("`vceextra'"!="") local vceextra , `vceextra'
	local vceoption "`vcetype'`temp_clustervars'`vceextra'" // this excludes "vce(", only has the contents


* DoF Adjustments
	if ("`dofadjustments'"=="") local dofadjustments all
	local 0 , `dofadjustments'
	syntax, [ALL NONE] [PAIRwise FIRSTpair] [CLusters] [CONTinuous]
	opts_exclusive "`all' `none'" dofadjustments
	opts_exclusive "`pairwise' `firstpair'" dofadjustments
	if ("`none'"!="") {
		Assert "`pairwise'`firstpair'`clusters'`continuous'"=="", msg("option {bf:dofadjustments()} invalid; {bf:none} not allowed with other alternatives")
		local dofadjustments
	}
	if ("`all'"!="") {
		Assert "`pairwise'`firstpair'`clusters'`continuous'"=="", msg("option {bf:dofadjustments()} invalid; {bf:all} not allowed with other alternatives")
		local dofadjustments pairwise clusters continuous
	}
	else {
		local dofadjustments `pairwise' `firstpair' `clusters' `continuous'
	}

* Mobility groups
	if ("`group'"!="") conf new var `group'

* IV options
	if ("`small'"!="") di in ye "(note: reghdfe will always use the option -small-, no need to specify it)"

	Assert ("`gmm2s'`liml'`cue'"==""), msg("options gmm2s/liml/cue not allowed")
	
	if ("`model'"=="iv") {
		local savefirst = ("`savefirst'"!="")
		local first = ("`first'"!="")
		if (`savefirst') Assert `first', msg("Option -savefirst- requires -first-")
	}

} // End of !`savingcache'

* Optimization
	if (`maxiterations'==0) local maxiterations 1e7
	Assert (`maxiterations'>0)
	local accelerate = cond("`accelerate'"!="", 0, 1) // 1=Yes
	local check = cond("`check'"!="", 1, 0) // 1=Yes
	local fast = cond("`fast'"!="", 1, 0) // 1=Yes
	local tolerance = strofreal(`tolerance', "%9.1e") // Purely esthetic
	Assert `cores'<=32 & `cores'>0 , msg("At most 32 cores supported")
	if (`cores'>1) {
		cap findfile parallel.ado
		Assert !_rc , msg("error: -parallel- not installed, please run {stata ssc install parallel}")
	}
	local opt_list tolerance maxiterations check accelerate ///
		bad_loop_threshold stuck_threshold pause_length accel_freq accel_start
	foreach opt of local opt_list {
		if ("``opt''"!="") local maximize_options `maximize_options' `opt'(``opt'')
	}

* Varnames underlying tsvars and fvvars (e.g. i.foo L(1/3).bar -> foo bar)
	foreach vars in depvar indepvars endogvars instruments {
		if ("``vars''"!="") {
			fvrevar ``vars'' , list
			local basevars `basevars' `r(varlist)'
		}
	}

if (!`savingcache') {
* Nested
	local nested = cond("`nested'"!="", 1, 0) // 1=Yes
	if (`nested' & !("`model'"=="ols" & "`vcetype'"=="unadjusted") ) {
		Debug, level(0) msg("(option nested ignored, only works with OLS and conventional/unadjusted VCE)") color("error")
	}

* How can we do the same regression from a standard stata command?
* (useful for benchmarking and testing correctness of results)
	local subcmd = cond("`model'"=="ols" ,"regress", "`ivsuite'")

* _fv_check_depvar overwrites the local -weight-
	local weight `backupweight'
	Assert inlist( ("`weight'"!="") + ("`weightvar'"!="") + ("`weightexp'"!="") , 0 , 3 ) , msg("not all 3 weight locals are set")

* Return values
	local names cmdline diopts model ///
		ivsuite showraw ///
		depvar indepvars endogvars instruments savefirst first ///
		vceoption vcetype vcesuite vceextra num_clusters clustervars /// vceextra
		dofadjustments ///
		if in group check fast nested fe_format ///
		tolerance maxiterations accelerate maximize_options ///
		subcmd suboptions ///
		absorb avge excludeself ///
		timevar panelvar basevars ///
		addconstant ///
		weight weightvar exp weightexp /// type of weight (fw,aw,pw), weight var., and full expr. ([fw=n])
		cores savingcache usecache over
}

if (`savingcache') {
	local names maximize_options cores if in timevar panelvar indepvars basevars ///
		absorb savecache savingcache fast nested check over ///
		weight weightvar exp weightexp /// type of weight (fw,aw), weight var., and full expr. ([fw=n])
		tolerance maxiterations // Here just used for -verbose- and cache handshake purposes
}

	local if `ifopt'
	local in `inopt'

	Debug, level(3) newline
	Debug, level(3) msg("Parsed options:")
	foreach name of local names {
		if (`"``name''"'!="") Debug, level(3) msg("  `name' = " as result `"``name''"')
		c_local `name' `"``name''"' // Inject values into caller (reghdfe.ado)
	}
	// Debug, level(3) newline
end

	
//------------------------------------------------------------------------------
// Expand Factor Variables, interactions, and time-series vars
//------------------------------------------------------------------------------
// This basically wraps -fvrevar-, adds labels, and drops omitted/base
program define ExpandFactorVariables, rclass
syntax varlist(min=1 numeric fv ts) [if] [,setname(string)] [CACHE]

	local expanded_msg `"" - variable expansion for `setname': " as result "`varlist'" as text " ->""'

	* It's (usually) a waste to add base and omitted categories
	* EG: if we use i.foreign#i.rep78 , several categories will be redundant, seen as e.g. "0b.foreign" in -char list-
	* We'll also exclude base categories that don't have the "bn" option (to have no base)

	* Loop for each var and then expand them into i.var -> 1.var.. and loop
	* Why two loops? B/c I want to save each var expansion to allow for a cache

	if ("`cache'"!="") mata: varlist_cache = asarray_create()

	local newvarlist
	* I can't do a simple foreach!
	* Because a factor expression could be io(3 4).rep78
	* and foreach would split the parens in half
	while (1) {
	gettoken fvvar varlist : varlist, bind
	if ("`fvvar'"=="") continue, break

		fvrevar `fvvar' `if' // , stub(__V__) // stub doesn't work in 11.2
		local contents

		foreach var of varlist `r(varlist)' {
			
			* Get readable varname
			local fvchar : char `var'[fvrevar]
			local tschar : char `var'[tsrevar]
			local name `fvchar'`tschar'
			local color input
			if ("`name'"=="") {
				local name `var'
				local color result
			}
			char `var'[name] `name'
			la var `var' "[Tempvar] `name'"

			* See if the factor can be dropped safely
			if (substr("`var'", 1, 2)=="__") {
				local color result
				local parts : subinstr local fvchar "#" " ", all
				foreach part of local parts {
					* "^[0-9]+b\." -> "b.*\."
					if regexm("`part'", "b.*\.") | regexm("`part'", "o.*\.") {
						local color error	
						drop `var'
						continue, break
					}
				}


				* Need to rename it, or else it gets dropped since its a tempvar
				if ("`color'"!="error") {
					local newvarbase : subinstr local name "." "__", all // pray that no variable has three _
					local newvarbase : subinstr local newvarbase "#" "_X_", all // idem
					local newvarbase : permname __`newvarbase', length(30)
					local i 0
					while (1) {
						local newvar "`newvarbase'`++i'"
						Assert `i'<1000, msg("Couldn't create tempvar for `var' (`name')")
						cap conf new var `newvar', exact
						if _rc==0 {
							continue, break
						}
					}
					rename `var' `newvar'
					local var `newvar'
				}
			}

			* Save contents of the expansion for optional -cache-			
			if ("`color'"!="error") {
				local contents `contents' `var'
			}
			
			* Set debug message
			local expanded_msg `"`expanded_msg' as `color' " `name'" as text " (`var')""'
		}

		if ("`cache'"!="") mata: asarray(varlist_cache, "`fvvar'", "`contents'")
		Assert "`contents'"!="", msg("error: variable -`fvvar'- in varlist -`varlist'- in category -`setname'- is  empty after factor expansion")
		local newvarlist `newvarlist' `contents'
	}

	* Yellow=Already existed, White=Created, Red=NotCreated (omitted or base)
	Debug, level(3) msg(`expanded_msg')
	return local varlist "`newvarlist'"
end

	
// -------------------------------------------------------------------------------------------------
// Calculate the degrees of freedom lost due to the absorbed fixed effects
// -------------------------------------------------------------------------------------------------
/*
	In general, we can't know the exact number of DoF lost because we don't know when multiple FEs are collinear
	When we have two pure FEs, we can use an existing algorithm, but besides that we'll just use an upper (conservative) bound

	Features:
	 - Save the first mobility group if asked
	 - Within the pure FEs, we can use the existing algorithm pairwise (FE1 vs FE2, FE3, .., FE2 vs FE3, ..)
	 - If there are n pure FEs, that means the algo gets called n! times, which may be kinda slow
	 - With FEs interacted with continuous variables, we can't do this, but can do two things:
		a) With i.a#c.b , whenever b==0 for all values of a group (of -a-), add one redundant
		b) With i.a##c.b, do the same but whenever b==CONSTANT (so not just zero)
     - With clusters, it gets trickier but in summary you don't need to penalize DoF for params that only exist within a cluster. This happens:
		a) if absvar==clustervar
		b) if absvar is nested within a clustervar. EG: if we do vce(cluster state), and -absorb(district)- or -absorb(state#year)
		c) With cont. interactions, e.g. absorb(i.state##c.year) vce(cluster year), then i) state FE is redundant, but ii) also state#c.year
		   The reason is that at the param for each "fixed slope" is shared only within a state

	Procedure:
	 - Go through all FEs and see if i) they share the same ivars as any clusters, and if not, ii) if they are nested within clusters
	 - For each pure FE in the list, run the algorithm pairwise, BUT DO NOT RUN IT BEETWEEN TWO PAIRS OF redundant
	   (since the redundants are on the left, we just need to check the rightmost FE for whether it was tagged)
	 - For the ones with cont interactions, do either of the two tests depending on the case

	Misc:
	 - There are two places where DoFs enter in the results:
		a) When computing e(V), we do a small sample adjustment (seen in Stata documentation as the -q-)
		   Instead of doing V*q with q = N/(N-k), we use q = N / (N-k-kk), so THE PURPOSE OF THIS PROGRAM IS TO COMPUTE "kk"
		   This kk will be used to adjust V and also stored in e(df_a)
		   With clusters, q = (N-1) / (N-k-kk) * M / (M-1)
		   With multiway clustering, we use the smallest N_clust as our M
	    b) In the DoF of the F and t tests (not when doing chi/normal)
	       When there are clusters, note that e(df_r) is M-1 instead of N-1-k
	       Again, here we want to use the smallest M with multiway clustering

	Inputs: +-+- if we just use -fe2local- we can avoid passing stuff around when building subroutines
	 - We need the current name of the absvars and clustervars (remember a#b is replaced by something different)
	 - Do a conf var at this point to be SURE that we didn't mess up before
	 - We need the ivars and cvars in a list
	 - For the c. interactions, we need to know if they are bivariate or univariate
	 - SOLN -> reghdfe_absorb, fe2local(`g')  ; from mata: ivars_clustervar`i' (needed???) , and G
	 - Thus, do we really needed the syntax part??
	 - fe2local saves: ivars cvars target varname varlabel is_interaction is_cont_interaction is_bivariate is_mock levels // Z group_k weightvar

	DOF Syntax:
	 DOFadjustments(none | all | CLUSTERs | PAIRwise | FIRSTpair | CONTinuous)
	 dof() = dof(all) = dof(cluster pairwise continuous)
	 dof(none) -> do nothing; all Ms = 0 
	 dof(first) dof(first cluster) dof(cluster) dof(continuous)

	For this to work, the program MUST be modular
*/
program define EstimateDoF, rclass
syntax, [DOFadjustments(string) group(name) uid(varname) groupdta(string)]
	
	* Parse list of adjustments/tricks to do
	Debug, level(1) msg("(calculating degrees of freedom lost due to the FEs)")
	local adjustement_list firstpairs pairwise clusters continuous
	* This allows doing things like <if (`adj_clusters') ..>
	Debug, level(2) msg(`" - Adjustments:"')
	foreach adj of local adjustement_list {
		local adj_`adj' : list posof "`adj'" in dofadjustments
		Debug, level(2) msg(`"    - `adj' {col 18}{res} `=cond(`adj_`adj'',"yes","no")'"')
	}

	* Assert that the clustervars exist
	mata: st_local("clustervars", invtokens(clustervars))
	conf variable `clustervars', exact

	mata: st_local("G", strofreal(G))
	mata: st_local("N_clustervars", strofreal(length(clustervars)))

	if ("`group'"!="") {
		local group_option ", gen(`group')"
		Assert (`adj_firstpairs' | `adj_pairwise'), msg("Cannot save connected groups without options pairwise or firstpair")
	}

	* Remember: fe2local stores the following:
	* ivars cvars target varname varlabel is_interaction is_cont_interaction is_bivariate is_mock levels

* Starting point assumes no redundant parameters
	forv g=1/`G' {
		reghdfe_absorb, fe2local(`g')
		local redundant`g' = 0 // will be 1 if we don't penalize at all for this absvar (i.e. if it's nested with cluster or collinear with another absvar)
		local is_slope`g' = ("`cvars'"!="") & (!`is_bivariate' | `is_mock') // two cases: i.a#c.b , i.a##c.b (which expands to <i.a i.a#c.b> and we want the second part)
		local M`g' = !`is_slope`g'' // Start with 0 with cont. interaction, 1 w/out cont interaction

		*For each FE, only know exactly parameters are redundant in a few cases:
		*i) nested in cluster, ii) first pure FE, iii) second pure FE if checked with connected groups
		local exact`g' 0
		local drop`g' = !(`is_bivariate' & `is_mock')
	}

* Check if an absvar is a clustervar or is nested in a clustervar
* We *always* check if absvar is a clustervar, to prevent deleting its __FE__ variable by mistake
* But we only update the DoF if `adj_clusters' is true.

	local M_due_to_nested 0 // Redundant DoFs due to nesting within clusters
	if (`N_clustervars'>0) {
		mata: st_local("clustervars", invtokens(clustervars))
		forv g=1/`G' {
			reghdfe_absorb, fe2local(`g')
			local gg = `g' - `is_mock'
			local absvar_in_clustervar 0 // 1 if absvar is nested in a clustervar
			
			* Trick: if the absvar is also a clustervar, then its name will be __FE*__
			local absvar_is_clustervar : list varname in clustervars
			if (`adj_clusters' & `absvar_is_clustervar') {
				Debug, level(1) msg("(categorical variable " as result "`varlabel'"as text " is also a cluster variable, so it doesn't count towards DoF)")
			}
			else if (`adj_clusters') {
				forval i = 1/`N_clustervars' {
					mata: st_local("clustervar", clustervars[`i'])
					mata: st_local("clustervar_original", clustervars_original[`i'])
					cap _xtreg_chk_cl2 `clustervar' __FE`gg'__
					assert inlist(_rc, 0, 498)
					if (!_rc) {
						Debug, level(1) msg("(categorical variable " as result "`varlabel'" as text " is nested within cluster variable " as result "`clustervar_original'" as text ", so it doesn't count towards DoF)")
						continue, break
					}
				}
			}

			if (`absvar_is_clustervar') local drop`g' 0

			if ( `adj_clusters' & (`absvar_is_clustervar' | `absvar_in_clustervar') ) {
				local M`g' = `levels'
				local redundant`g' 1
				local exact`g' 1
				local M_due_to_nested = `M_due_to_nested' + `levels' - 1
			}
		} // end for over absvars
	} // end cluster adjustment

* Just indicate the first pure FE that is not nested in a cluster
	forv g=1/`G' {
		if (!`is_slope`g'' & !`redundant`g'') {
			local exact`g' 1
			continue, break
		}
	}

* Compute connected groups for the remaining FEs (except those with cont interactions)
	local dof_exact 0 // if this code never runs, it's not exact
	if (`adj_firstpairs' | `adj_pairwise') {
		Debug, level(3) msg(" - Calculating connected groups for DoF estimation")
		local dof_exact 1
		local i_comparison 0
		forv g=1/`G' {
			if (`is_slope`g'') local dof_exact 0 // We may not get all redundant vars with cont. interactions
			if (`is_slope`g'') continue
			local start_h = `g' + 1
			forv h=`start_h'/`G' {
				if (`is_slope`h'' | `redundant`h'') continue
				local ++i_comparison
				if (`i_comparison'>1) local dof_exact 0 // Only exact with one comparison
				if (`i_comparison'>1 & `adj_firstpairs') continue // -firstpairs- will only run the first comparison
				if (`i_comparison'==1) local exact`h' 1
				ConnectedGroups __FE`g'__ __FE`h'__ `group_option'
				local group_option // connected groups are only saved *once*
				local candidate = r(groups)
				local M`h' = max(`M`h'', `candidate')
			}
		}
	} // end connected group comparisons

* Adjustment with cont. interactions
	if (`adj_continuous') {
		forv g=1/`G' {
			reghdfe_absorb, fe2local(`g')
			if (!`is_slope`g'') continue
			CheckZerosByGroup, fe(`varname') cvars(`cvars') anyconstant(`is_mock')
			local M`g' = r(redundant)
		}
	}

	if (`dof_exact') {
		Debug, level(1) msg(" - DoF computation is exact")
	}
	else {
		Debug, level(1) msg(" - DoF computation not exact; DoF may be higher than reported")	
	}

	local SumM 0
	local SumK 0
	Debug, level(2) msg(" - Results of DoF adjustments:")
	forv g=1/`G' {
		reghdfe_absorb, fe2local(`g')
		assert !missing(`M`g'') & !missing(`levels')
		local SumM = `SumM' + `M`g''
		local SumK = `SumK' + `levels'

		return scalar M`g' = `M`g''
		return scalar K`g' = `levels'
		return scalar M`g'_exact = `exact`g''
		return scalar drop`g' = `drop`g''
		Debug, level(2) msg("   - FE`g' ({res}`varlabel'{txt}): {col 40}K=`levels' {col 50}M=`M`g'' {col 60}is_exact=`exact`g''")
	}
	return scalar M = `SumM'
	local NetSumK = `SumK' - `SumM'
	Debug, level(2) msg(" - DoF loss due to FEs: Sum(Kg)=`SumK', M:Sum(Mg)=`SumM' --> KK:=SumK-SumM=`NetSumK'")
	return scalar kk = `NetSumK'

* Save mobility group if needed
	local saved_group = 0
	if ("`group'"!="") {
		conf var `group'
		tempfile backup
		qui save "`backup'"
		
		keep `uid' `group'
		sort `uid'
		la var `group' "Mobility group between `label'"
		qui save "`groupdta'" // A tempfile from the caller program
		Debug, level(2) msg(" - mobility group saved")
		qui use "`backup'", clear
		cap erase "`backup'"
		local saved_group = 1
	}
	return scalar saved_group = `saved_group'
	return scalar M_due_to_nested = `M_due_to_nested'
end

capture program drop CheckZerosByGroup
program define CheckZerosByGroup, rclass sortpreserve
syntax, fe(varname numeric) cvars(varname numeric) anyconstant(integer)
	tempvar redundant
	assert inlist(`anyconstant', 0, 1)
	if (`anyconstant') {
		qui bys `fe' (`cvars'): gen byte `redundant' = (`cvars'[1]==`cvars'[_N]) if (_n==1)
	}
	else {
		qui bys `fe' (`cvars'): gen byte `redundant' = (`cvars'[1]==0 & `cvars'[_N]==0) if (_n==1)
	}
	qui cou if `redundant'==1
	return scalar redundant = r(N)
end

		
// -------------------------------------------------------------
// Faster alternative to -makegps-, but with some limitations
// -------------------------------------------------------------
* To avoid backuping the data, use option -clear-
* For simplicity, disallow -if- and -in- options
program ConnectedGroups, rclass
syntax varlist(min=2 max=2) [, GENerate(name) CLEAR]

* To avoid backuping the data, use option -clear-
* For simplicity, disallow -if- and -in- options

    if ("`generate'"!="") conf new var `generate'
    gettoken id1 id2 : varlist
    Debug, level(2) msg("    - computing connected groups between `id1' and`id2'")
    tempvar group copy

    tempfile backup
    if ("`clear'"=="") qui save "`backup'"
    keep `varlist'
    qui bys `varlist': keep if _n==1


    clonevar `group' = `id1'
    clonevar `copy' = `group'
    capture error 100 // We want an error
    while _rc {
        qui bys `id2' (`group'): replace `group' = `group'[1]
        qui bys `id1' (`group'): replace `group' = `group'[1]
        capture assert `copy'==`group'
        qui replace `copy' = `group'
    }

    assert !missing(`group')
    qui bys `group': replace `group' = (_n==1)
    qui replace `group' = sum(`group')
    
    su `group', mean
    local num_groups = r(max)
    
    if ("`generate'"!="") rename `group' `generate'
    
    if ("`clear'"=="") {
        if ("`generate'"!="") {
            tempfile groups
            qui compress
            la var `generate' "Mobility group for (`varlist')"
            qui save "`groups'"
            qui use "`backup'", clear
            qui merge m:1 `id1' `id2' using "`groups'" , assert(match) nogen
        }
        else {
            qui use "`backup'", clear
        }
    }
    
    return scalar groups=`num_groups'
end

	
//------------------------------------------------------------------------------
// Name tempvars into e.g. L.x i1.y i2.y AvgE:z , etc.
//------------------------------------------------------------------------------
program define FixVarnames, rclass
local vars `0'

	foreach var of local vars {
		local newname
		local pretyname

		* -var- can be <o.__W1__>
		if ("`var'"=="_cons") {
			local newname `var'
			local prettyname `var'
		}
		else {
			fvrevar `var', list
			local basevar "`r(varlist)'"
			local label : var label `basevar'
			local is_avge = regexm("`basevar'", "^__W[0-9]+__$")
			local is_temp = substr("`basevar'",1,2)=="__"
			local is_omitted = strpos("`var'", "o.")
			local prefix = cond(`is_omitted'>0, "o.", "")
			local name : char `basevar'[name]

			if (`is_avge') {
				local avge_str : char `basevar'[avge_equation]
				local name : char `basevar'[name]
				local prettyname `avge_str':`prefix'`name'

				local newname : char `basevar'[target]
				if ("`newname'"=="") local newname `var'
			}
			else if (`is_temp' & "`name'"!="") {
				local newname `prefix'`name' // BUGBUG
				local prettyname `newname'
			}
			else {
				local newname `var'
				local prettyname `newname'
			}
		}
		
		* di in red " var=<`var'> --> new=<`newname'> pretty=<`prettyname'>"
		Assert ("`newname'"!="" & "`prettyname'"!=""), ///
			msg("var=<`var'> --> new=<`newname'> pretty=<`prettyname'>")
		local newnames `newnames' `newname'
		local prettynames `prettynames' `prettyname'
	}

	local A : word count `vars'
	local B : word count `newnames'
	local C : word count `prettynames'
	Assert `A'==`B', msg("`A' vars but `B' newnames")
	Assert `A'==`C', msg("`A' vars but `C' newnames")
	
	***di as error "newnames=`newnames'"
	***di as error "prettynames=`prettynames'"

	return local newnames "`newnames'"
	return local prettynames "`prettynames'"
end

	
/* Notes:
- For -cluster- I need to run two regressions as in xtreg; the first one is to get the df_m

- El FTEST es distinto entre areg/reg y xtreg porque xtreg hace un ajuste extra
para pasar de areg a xtreg, multiplicar el F por Q^2
Donde Q =  (e(N) - e(rank)) / (e(N) - e(rank) - e(df_a))
Es decir, en vez de dividir entre N-K-KK, me basta con dividir entre N-K
Asi que me bastaria usar -test- despues de correr la regresion y deberia salir igual que el FTEST ajustado del areg!!!
(tambien igual al del xreg pero eso es mas limitante , aunq igual probar para 1 HDFE creando t=_n a nivel del ID1)
*/
*/
program define Wrapper_regress, eclass
	syntax , depvar(varname) [indepvars(varlist) avgevars(varlist)] ///
		original_absvars(string) original_depvar(string) [original_indepvars(string) avge_targets(string)] ///
		vceoption(string asis) vcetype(string) ///
		kk(integer) ///
		[weightexp(string)] ///
		addconstant(integer) ///
		[SUBOPTions(string)] [*] // [*] are ignored!

	if ("`options'"!="") Debug, level(3) msg("(ignored options: `options')")
	if (`c(version)'>=12) local hidden hidden

	local vceoption : subinstr local vceoption "unadjusted" "ols"
	local vceoption "vce(`vceoption')"
	mata: st_local("vars", strtrim(stritrim( "`depvar' `indepvars' `avgevars'" )) ) // Just for esthetic purposes

* Hide constant
	if (!`addconstant') {
		local nocons noconstant
		local kk = `kk' + 1
	}

* Run regression just to compute true DoF
	local subcmd _regress `vars' `weightexp', noheader notable `suboptions'
	Debug, level(3) msg("Subcommand: " in ye "`subcmd'")
	qui `subcmd'
	local N = e(N)
	local K = e(df_m) // Should also be equal to e(rank)+1
	*** scalar `sse' = e(rss)
	local WrongDoF = `N' - `addconstant' - `K'
	local CorrectDoF = `WrongDoF' - `kk' // kk = Absorbed DoF
	Assert !missing(`CorrectDoF')
	
* Now run intended regression and fix VCV
	local subcmd regress `vars' `weightexp', `vceoption' noheader notable `suboptions' `nocons'
	Debug, level(3) msg("Subcommand: " in ye "`subcmd'")
	qui `subcmd'
	
	* Fix DoF
	tempname V
	cap matrix `V' = e(V) * (`WrongDoF' / `CorrectDoF')

	* Avoid corner case error when all the RHS vars are collinear with the FEs
	if (`K'>0) {
		cap ereturn repost V=`V' // Else the fix would create MVs and we can't post
		Assert inlist(_rc,0,504), msg("error `=_rc' when adjusting the VCV")
	}
	else {
		ereturn scalar rank = 1 // Set e(rank)==1 when e(df_m)=0 , due to the constant
		* (will not be completely correct if model is already demeaned?)
	}
	
	*** if ("`vcetype'"!="cluster") ereturn scalar rank = e(rank) + `kk'

* ereturns specific to this command
	ereturn scalar df_r = max(`CorrectDoF', 0)
	mata: st_local("original_vars", strtrim(stritrim( "`original_depvar' `original_indepvars' `avge_targets' `original_absvars'" )) )

	if ("`vcetype'"!="cluster") { // ("`vcetype'"=="unadjusted")
		ereturn scalar F = e(F) * `CorrectDoF' / `WrongDoF'
		if missing(e(F)) di as error "WARNING! Missing FStat"
	}
	else {
		ereturn `hidden' scalar unclustered_df_r = `CorrectDoF'
		assert e(N_clust)<.
	}


	local run_test = ("`vcetype'"=="cluster") | ( e(df_m)+1!=e(rank) )
	if (`run_test') {
		if ("`vcetype'"!="cluster") {
			Debug, level(0) msg("Note: equality df_m+1==rank failed (is there a collinear variable in the RHS?), running -test- to get correct values")
		}
		return clear
		if (`K'>0) {
			qui test `indepvars' `avge' // Wald test
			ereturn scalar F = r(F)
			ereturn scalar df_m = r(df)
			ereturn scalar rank = r(df)+1 // Add constant
		}
		else {
			ereturn scalar F = 0
			ereturn scalar df_m = 0
			ereturn scalar rank = 1
		}
	}

* Fstat
	* _U: Unrestricted, _R: Restricted
	* FStat = (RSS_R - RSS_U) / RSS * (N-K) / q
	*       = (R2_U - R2_R) / (1 - R2_U) * DoF_U / (DoF_R - DoF_U)
	Assert e(df_m)+1==e(rank) , rc(0) msg("Error: expected e(df_m)+1==e(rank), got (`=`e(df_m)'+1'!=`e(rank)')")
end

* Cluster notes (see stata PDFs):
* We don't really have "N" indep observations but "M" (aka `N_clust') superobservations,
* and we are replacing (N-K) DoF with (M-1) (used when computing the T and F tests)
		
* For the VCV matrix, the multiplier (small sample adjustement) is q := (N-1)/(N-K) * M / (M-1)
* Notice that if every obs is its own cluster, M=N and q = N/(N-K) (the usual multiplier for -ols- and -robust-)
		
* Also, if one of the absorbed FEs is nested within the cluster variable, then we don't need to include that variable in K
* (this is the adjustment that xtreg makes that areg doesn't)

	
capture program drop Wrapper_mwc
program define Wrapper_mwc, eclass
* This will compute an ols regression with 2+ clusters
syntax , depvar(varname) [indepvars(varlist) avgevars(varlist)] ///
	original_absvars(string) original_depvar(string) [original_indepvars(string) avge_targets(string)] ///
	vceoption(string asis) ///
	kk(integer) ///
	[weightexp(string)] ///
	addconstant(integer) ///
	[SUBOPTions(string)] [*] // [*] are ignored!

	if ("`options'"!="") Debug, level(3) msg("(ignored options: `options')")
	mata: st_local("vars", strtrim(stritrim( "`depvar' `indepvars' `avgevars'" )) ) // Just for esthetic purposes
	if (`c(version)'>=12) local hidden hidden

* Parse contents of VCE()
	local 0 `vceoption'
	syntax namelist(max=11) // Of course clustering by anything beyond 2-3 is insane
	gettoken vcetype clustervars : namelist
	assert "`vcetype'"=="cluster"
	local clustervars `clustervars' // Trim

* Hide constant
	if (!`addconstant') {
		local nocons noconstant
		local kk = `kk' + 1
	}

* Obtain e(b), e(df_m), and resids
	local subcmd regress `depvar' `indepvars' `avgevars' `weightexp', `nocons'
	Debug, level(3) msg("Subcommand: " in ye "`subcmd'")
	qui `subcmd'

	local K = e(df_m)
	local WrongDoF = e(df_r)

	* Store some results for the -ereturn post-
	tempname b
	matrix `b' = e(b)
	local N = e(N)
	local marginsok = e(marginsok)
	local rmse = e(rmse)
	local rss = e(rss)

	local predict = e(predict)
	local cmd = e(cmd)
	local cmdline = e(cmdline)
	local title = e(title)

	* Compute the bread of the sandwich D := inv(X'X/N)
	tempname XX invSxx
	qui mat accum `XX' = `indepvars' `avgevars', `nocons'
	mat `invSxx' = syminv(`XX') // This line is different from <Wrapper_avar>

	* Resids
	tempvar resid
	predict double `resid', resid

	* DoF
	local df_r = max( `WrongDoF' - `kk' , 0 )

* Use MWC to get meat of sandwich "M" (notation: V = DMD)
	local size = rowsof(`invSxx')
	tempname M V // Will store the Meat and the final Variance
	matrix `V' = J(`size', `size', 0)

* This gives all the required combinations of clustervars (ssc install tuples)
	tuples `clustervars' // create locals i) ntuples, ii) tuple1 .. tuple#
	tempvar group
	local N_clust = .
	local j 0

	forval i = 1/`ntuples' {
		matrix `M' =  `invSxx'
		local vars `tuple`i''
		local numvars : word count `vars'
		local sign = cond(mod(`numvars', 2), "+", "-") // + with odd number of variables, - with even

		GenerateID `vars', gen(`group')
		
		if (`numvars'==1) {
			su `group', mean
			local N_clust`++j' = r(max)
			local N_clust = min(`N_clust', r(max))
			Debug, level(2) msg(" - multi-way-clustering: `vars' has `r(max)' groups")
		}
		
		* Compute the full sandwich (will be saved in `M')

		_robust `resid', variance(`M') minus(0) cluster(`group') // Use minus==1 b/c we adjust the q later
		Debug, level(3) msg(as result "`sign' `vars'")
		* Add it to the other sandwiches
		matrix `V' = `V' `sign' `M'
		drop `group'
	}

	local N_clustervars = `j'

* If the VCV matrix is not positive-semidefinite, use the fix from
* Cameron, Gelbach & Miller - Robust Inference with Multi-way Clustering (JBES 2011)
* 1) Use eigendecomposition V = U Lambda U' where U are the eigenvectors and Lambda = diag(eigenvalues)
* 2) Replace negative eigenvalues into zero and obtain FixedLambda
* 3) Recover FixedV = U * FixedLambda * U'
* This will fail if V is not symmetric (we could use -mata makesymmetric- to deal with numerical precision errors)
	mata: fix_psd("`V'") // This will update `V' making it PSD
	assert inlist(`eigenfix', 0, 1)
	if (`eigenfix') Debug, level(0) msg("VCV matrix was non-positive semi-definite; adjustment from Cameron, Gelbach & Miller applied.")

	local M = `N_clust' // cond( `N_clust' < . , `N_clust' , `N' )
	local q = ( `N' - 1 ) / `df_r' * `M' / (`M' - 1) // General formula, from Stata PDF
	matrix `V' = `V' * `q'

	* At this point, we have the true V and just need to add it to e()

	local unclustered_df_r = `df_r' // Used later in R2 adj
	local df_r = `M' - 1 // Cluster adjustment

	capture ereturn post `b' `V' `weightexp', dep(`depvar') obs(`N') dof(`df_r') properties(b V)

	local rc = _rc
	Assert inlist(_rc,0,504), msg("error `=_rc' when adjusting the VCV") // 504 = Matrix has MVs
	Assert `rc'==0, msg("Error: estimated variance-covariance matrix has missing values")
	ereturn local marginsok = "`marginsok'"
	ereturn local predict = "`predict'"
	ereturn local cmd = "`cmd'"
	ereturn local cmdline = "`cmdline'"
	ereturn local title = "`title'"
	ereturn scalar rmse = `rmse'
	ereturn scalar rss = `rss'
	ereturn `hidden' scalar unclustered_df_r = `unclustered_df_r'

	ereturn local clustvar = "`clustervars'"
	assert `N_clust'<.
	ereturn scalar N_clust = `N_clust'
	forval i = 1/`N_clustervars' {
		ereturn scalar N_clust`i' = `N_clust`i''
	}

* Compute model F-test
	if (`K'>0) {
		qui test `indepvars' `avge' // Wald test
		ereturn scalar F = r(F)
		ereturn scalar df_m = r(df)
		ereturn scalar rank = r(df)+1 // Add constant
		if missing(e(F)) di as error "WARNING! Missing FStat"
	}
	else {
		ereturn scalar F = 0
		ereturn df_m = 0
		ereturn scalar rank = 1
	}

* ereturns specific to this command
	mata: st_local("original_vars", strtrim(stritrim( "`original_depvar' `original_indepvars' `avge_targets' `original_absvars'" )) )

end
program define Wrapper_avar, eclass
	syntax , depvar(varname) [indepvars(varlist) avgevars(varlist)] ///
		original_absvars(string) original_depvar(string) [original_indepvars(string) avge_targets(string)] ///
		vceoption(string asis) ///
		kk(integer) ///
		[weightexp(string)] ///
		addconstant(integer) ///
		[SUBOPTions(string)] [*] // [*] are ignored!

	if ("`options'"!="") Debug, level(3) msg("(ignored options: `options')")
	mata: st_local("vars", strtrim(stritrim( "`depvar' `indepvars' `avgevars'" )) ) // Just for esthetic purposes
	if (`c(version)'>=12) local hidden hidden

* Convert -vceoption- to what -avar- expects
	local 0 `vceoption'
	syntax namelist(max=3) , [bw(string) dkraay(string) kernel(string) kiefer]
	gettoken vcetype clustervars : namelist
	local clustervars `clustervars' // Trim
	Assert inlist("`vcetype'", "unadjusted", "robust", "cluster")
	local vceoption = cond("`vcetype'"=="unadjusted", "", "`vcetype'")
	if ("`clustervars'"!="") local vceoption `vceoption'(`clustervars')
	if ("`bw'"!="") local vceoption `vceoption' bw(`bw')
	if ("`dkraay'"!="") local vceoption `vceoption' dkraay(`dkraay')
	if ("`kernel'"!="") local vceoption `vceoption' kernel(`kernel')
	if ("`kiefer'"!="") local vceoption `vceoption' kiefer

* Hide constant
	if (!`addconstant') {
		local nocons noconstant
		local kk = `kk' + 1
	}

* Before -avar- we need:
*	i) inv(X'X)
*	ii) DoF lost due to included indepvars
*	iii) resids
* Note: It would be shorter to use -mse1- (b/c then invSxx==e(V)*e(N)) but then I don't know e(df_r)
	local subcmd regress `depvar' `indepvars' `avgevars' `weightexp', `nocons'
	Debug, level(3) msg("Subcommand: " in ye "`subcmd'")
	qui `subcmd'
	qui cou if !e(sample)
	assert r(N)==0

	local K = e(df_m) // Should also be equal to e(rank)+1
	local WrongDoF = e(df_r)

	* Store some results for the -ereturn post-
	tempname b
	matrix `b' = e(b)
	local N = e(N)
	local marginsok = e(marginsok)
	local rmse = e(rmse)
	local rss = e(rss)

	local predict = e(predict)
	local cmd = e(cmd)
	local cmdline = e(cmdline)
	local title = e(title)

	* Compute the bread of the sandwich inv(X'X/N)
	tempname XX invSxx
	qui mat accum `XX' = `indepvars' `avgevars', `nocons'
	mat `invSxx' = syminv(`XX' * 1/r(N))
	
	* Resids
	tempvar resid
	predict double `resid', resid

	* DoF
	local df_r = max( `WrongDoF' - `kk' , 0 )

* Use -avar- to get meat of sandwich
	local subcmd avar `resid' (`indepvars' `avgevars'), `vceoption' `nocons' // dofminus(0)
	Debug, level(3) msg("Subcommand: " in ye "`subcmd'")
	qui `subcmd'
	
* Get the entire sandwich
	* Without clusters it's as if every obs. is is own cluster
	local M = cond( r(N_clust) < . , r(N_clust) , r(N) )
	local q = ( `N' - 1 ) / `df_r' * `M' / (`M' - 1) // General formula, from Stata PDF
	tempname V
	matrix `V' = `invSxx' * r(S) * `invSxx' / r(N) // Large-sample version
	matrix `V' = `V' * `q' // Small-sample adjustments
	* At this point, we have the true V and just need to add it to e()

* Avoid corner case error when all the RHS vars are collinear with the FEs
	local unclustered_df_r = `df_r' // Used later in R2 adj
	if ("`clustervars'"!="") local df_r = `M' - 1

	capture ereturn post `b' `V' `weightexp', dep(`depvar') obs(`N') dof(`df_r') properties(b V)
	local rc = _rc
	Assert inlist(_rc,0,504), msg("error `=_rc' when adjusting the VCV") // 504 = Matrix has MVs
	Assert `rc'==0, msg("Error: estimated variance-covariance matrix has missing values")
	ereturn local marginsok = "`marginsok'"
	ereturn local predict = "`predict'"
	ereturn local cmd = "`cmd'"
	ereturn local cmdline = "`cmdline'"
	ereturn local title = "`title'"
	ereturn scalar rmse = `rmse'
	ereturn scalar rss = `rss'
	ereturn `hidden' scalar unclustered_df_r = `unclustered_df_r'

* Compute model F-test
	if (`K'>0) {
		qui test `indepvars' `avge' // Wald test
		ereturn scalar F = r(F)
		ereturn scalar df_m = r(df)
		ereturn scalar rank = r(df)+1 // Add constant
		if missing(e(F)) di as error "WARNING! Missing FStat"
	}
	else {
		ereturn scalar F = 0
		ereturn df_m = 0
		ereturn scalar rank = 1
	}

* ereturns specific to this command
	mata: st_local("original_vars", strtrim(stritrim( "`original_depvar' `original_indepvars' `avge_targets' `original_absvars'" )) )
end
program define Wrapper_ivregress, eclass
	syntax , depvar(varname) endogvars(varlist) instruments(varlist) ///
		[indepvars(varlist) avgevars(varlist)] ///
		original_depvar(string) original_endogvars(string) original_instruments(string) ///
		[original_indepvars(string) avge_targets(string)] ///
		vceoption(string asis) ///
		KK(integer) ///
		[weightexp(string)] ///
		addconstant(integer) ///
		SHOWRAW(integer) first(integer) ///
		[SUBOPTions(string)] [*] // [*] are ignored!

	mata: st_local("vars", strtrim(stritrim( "`depvar' `indepvars' `avgevars' (`endogvars'=`instruments')" )) )
	
	* Convert -vceoption- to what -ivreg2- expects
	local 0 `vceoption'
	syntax namelist(max=2)
	gettoken vceoption clustervars : namelist
	local clustervars `clustervars' // Trim
	Assert inlist("`vceoption'", "unadjusted", "robust", "cluster")
	if ("`clustervars'"!="") local vceoption `vceoption' `clustervars'
	local vceoption "vce(`vceoption')"

	local estimator 2sls
	*if ("`estimator'"=="gmm") local vceoption = "`vceoption' " + subinstr("`vceoption'", "vce(", "wmatrix(", .)
	
	* Note: the call to -ivregress- could be optimized.
	* EG: -ivregress- calls ereturn post .. ESAMPLE(..) but we overwrite the esample and its SLOW
	* But it's a 1700 line program so let's not worry about it
	*profiler on

* Hide constant
	if (!`addconstant') {
		local nocons noconstant
		local kk = `kk' + 1
	}

* Show first stage
	if (`first') {
		local firstoption "first"
	}

* Subcmd
	local subcmd ivregress `estimator' `vars' `weightexp', `vceoption' small `nocons' `firstoption' `suboptions'
	Debug, level(3) msg("Subcommand: " in ye "`subcmd'")
	local noise = cond(`showraw', "noi", "qui")
	`noise' `subcmd'
	
	*profiler off
	*profiler report
	
	* Fix DoF if needed
	local N = e(N)
	local K = e(df_m)
	local WrongDoF = `N' - `addconstant' - `K'
	local CorrectDoF = `WrongDoF' - `kk'
	Assert !missing(`CorrectDoF')
	if ("`estimator'"!="gmm" | 1) {
		tempname V
		matrix `V' = e(V) * (`WrongDoF' / `CorrectDoF')
		ereturn repost V=`V'
	}
	ereturn scalar df_r = `CorrectDoF'

	* ereturns specific to this command
	mata: st_local("original_vars", strtrim(stritrim( "`original_depvar' `original_indepvars' `avge_targets' `original_absvars' (`original_endogvars'=`original_instruments')" )) )
	if ("`estimator'"!="gmm") ereturn scalar F = e(F) * `CorrectDoF' / `WrongDoF'
end
program define Wrapper_ivreg2, eclass
	syntax , depvar(varname) endogvars(varlist) instruments(varlist) ///
		[indepvars(varlist) avgevars(varlist)] ///
		original_depvar(string) original_endogvars(string) original_instruments(string) ///
		[original_indepvars(string) avge_targets(string)] ///
		[original_absvars(string) avge_targets] ///
		vceoption(string asis) ///
		KK(integer) ///
		[SHOWRAW(integer 0)] first(integer) [weightexp(string)] ///
		addconstant(integer) ///
		[SUBOPTions(string)] [*] // [*] are ignored!
	if ("`options'"!="") Debug, level(3) msg("(ignored options: `options')")
	if (`c(version)'>=12) local hidden hidden
	
	* Disable some options
	local 0 , `suboptions'
	syntax , [SAVEFPrefix(name)] [*] // Will ignore SAVEFPREFIX
	local suboptions `options'
	assert (`addconstant'==0)

	* Convert -vceoption- to what -ivreg2- expects
	local 0 `vceoption'
	syntax namelist(max=3) , [bw(string) dkraay(string) kernel(string) kiefer]
	gettoken vcetype clustervars : namelist
	local clustervars `clustervars' // Trim
	Assert inlist("`vcetype'", "unadjusted", "robust", "cluster")
	local vceoption = cond("`vcetype'"=="unadjusted", "", "`vcetype'")
	if ("`clustervars'"!="") local vceoption `vceoption'(`clustervars')
	if ("`bw'"!="") local vceoption `vceoption' bw(`bw')
	if ("`dkraay'"!="") local vceoption `vceoption' dkraay(`dkraay')
	if ("`kernel'"!="") local vceoption `vceoption' kernel(`kernel')
	if ("`kiefer'"!="") local vceoption `vceoption' kiefer
	
	mata: st_local("vars", strtrim(stritrim( "`depvar' `indepvars' `avgevars' (`endogvars'=`instruments')" )) )
	
	if (`first') {
		local firstoption "first savefirst"
	}

	* Variables have already been demeaned, so we need to add -nocons- or the matrix of orthog conditions will be singular
	local subcmd ivreg2 `vars' `weightexp', `vceoption' `firstoption' small dofminus(`=`kk'+1') `suboptions' nocons
	Debug, level(3) msg(_n "call to subcommand: " _n as result "`subcmd'")
	local noise = cond(`showraw', "noi", "qui")
	`noise' `subcmd'
	if ("`noise'"=="noi") di in red "{hline 64}" _n "{hline 64}"

	if !missing(e(ecollin)) {
		di as error "endogenous covariate <`e(ecollin)'> was perfectly predicted by the instruments!"
		error 2000
	}

	if (`first') {
		ereturn `hidden' local first_prefix = "_ivreg2_"
		ereturn `hidden' local ivreg2_firsteqs = e(firsteqs)
		ereturn local firsteqs
	}

	foreach cat in exexog insts instd {
		FixVarnames `e(`cat')'
		ereturn local `cat' = "`r(newnames)'"
	}

	if (`first') {
		* May be a problem if we ran out of space for storing estimates
		local ivreg2_firsteqs "`e(ivreg2_firsteqs)'"
		tempname hold
		estimates store `hold' , nocopy
		foreach fs_eqn in `ivreg2_firsteqs' {
			qui estimates restore `fs_eqn'
			FixVarnames `e(depvar)'
			ereturn local depvar = r(prettynames)
			FixVarnames `e(inexog)'
			ereturn local inexog = r(prettynames)

			tempname b
			matrix `b' = e(b)
			local backup_colnames : colnames `b'
			FixVarnames `backup_colnames'
			matrix colnames `b' = `r(prettynames)' // newnames? prettynames?
			ereturn repost b=`b', rename

			estimates store `fs_eqn', nocopy
		}
		qui estimates restore `hold'
		estimates drop `hold'
	}

	* ereturns specific to this command
	mata: st_local("original_vars", strtrim(stritrim( "`original_depvar' `original_indepvars' `avge_targets' `original_absvars' (`original_endogvars'=`original_instruments')" )) )
end

	
capture program drop AddConstant
program define AddConstant
	syntax varlist(numeric)
	foreach var of local varlist {
		local mean : char `var'[mean]
		assert "`mean'"!=""
		assert !missing(`mean')
		qui replace `var' = `var' + `mean'
	}
end


// -------------------------------------------------------------
// Display Regression Table
// -------------------------------------------------------------
 program define Replay, eclass
	syntax , [*]
	Assert e(cmd)=="reghdfe"
	local subcmd = e(subcmd)
	Assert "`subcmd'"!="" , msg("e(subcmd) is empty")

	* Add pretty names for AvgE variables
	tempname b
	matrix `b' = e(b)
	local backup_colnames : colnames `b'
	matrix colnames `b' = `e(prettynames)'
	local savefirst = e(savefirst)
	local suboptions = e(suboptions)

	di as error "We need to add something like ivreg2 for the clusters.."
	di as error "We can use the LHS of header: Number of clusters (turn) = as result 18"
	
	di as error "Same for explaining unusual SEs with -avar- and -mwc-"
	di as error "like <Statistics robust to heteroskedasticity and clustering on turn and t>"
	di as error "like <and kernel-robust to common correlated disturbances (Driscoll-Kraay)>"
	di as error "<  kernel=Bartlett; bandwidth=2>"
	di as error "<  time variable (t):  t>"
	di as error "<  group variable (i): turn>"

	local diopts = "`e(diopts)'"
	if ("`options'"!="") { // Override
		_get_diopts diopts /* options */, `options'
	}

	if ("`subcmd'"=="ivregress") {
		* Don't want to display anova table or footnote
		_coef_table_header
		_coef_table, `diopts' bmatrix(`b') vmatrix(e(V)) // plus 
	}
	else if ("`subcmd'"=="ivreg2") {
		* Backup before showing both first and second stage
		tempname hold
		
		if ("`e(ivreg2_firsteqs)'"!="") {
			estimates store `hold'

			local i 0
			foreach fs_eqn in `e(ivreg2_firsteqs)' {
				local instrument  : word `++i' of `e(instd)'
				di as input _n "{title:First stage for `instrument'}"
				estimates replay `fs_eqn' , nohead `diopts'
				if (!`savefirst') estimates drop `fs_eqn'
			}

			ereturn clear
			qui estimates restore `hold'
			di as input _n "{title:Second stage}"
		}

		estimates store `hold'
		ereturn repost b=`b', rename
		ereturn local cmd = "`subcmd'"
		`subcmd' , `diopts'
		ereturn clear // Need this because -estimates restore- behaves oddly
		qui estimates restore `hold'
		assert e(cmd)=="reghdfe"
		estimates drop `hold'


		*ereturn local cmd = "reghdfe"
		*matrix `b' = e(b)
		*matrix colnames `b' = `backup_colnames'
		*ereturn repost b=`b', rename
	}
	else {

		* Regress-specific code, because it doesn't play nice with ereturn
		sreturn clear 

		if "`e(prefix)'" != "" {
			_prefix_display, `diopts'
			exit
		}
		_coef_table_header
		di
		local plus = cond(e(model)=="ols" & inlist("`e(vce)'", "unadjusted", "ols"), "plus", "")
		_coef_table, `plus' `diopts' bmatrix(`b') vmatrix(e(V))
	}

	reghdfe_footnote
	* Revert AvgE else -predict- and other commands will choke


end


// -------------------------------------------------------------
// Simple assertions
// -------------------------------------------------------------
program define Assert
    syntax anything(everything equalok) [, MSG(string asis) RC(integer 198)]
    if !(`anything') {
        di as error `msg'
        exit `rc'
    }
end


// -------------------------------------------------------------
// Simple debugging
// -------------------------------------------------------------
program define Debug

	syntax, [MSG(string asis) Level(integer 1) NEWline COLOR(string)] [tic(integer 0) toc(integer 0)]
	
	cap mata: st_local("VERBOSE",strofreal(VERBOSE)) // Ugly hack to avoid using a global
	if ("`VERBOSE'"=="") {
		di as result "Mata scalar -VERBOSE- not found, setting VERBOSE=3"
		local VERBOSE 3
		mata: VERBOSE = `VERBOSE'
	}


	assert "`VERBOSE'"!=""
	assert inrange(`level',0, 4)
	assert (`tic'>0) + (`toc'>0)<=1

	if ("`color'"=="") local color text
	assert inlist("`color'", "text", "res", "result", "error", "input")

	if (`VERBOSE'>=`level') {

		if (`tic'>0) {
			timer clear `tic'
			timer on `tic'
		}
		if (`toc'>0) {
			timer off `toc'
			qui timer list `toc'
			local time = r(t`toc')
			if (`time'<10) local time = string(`time'*1000, "%tcss.ss!s")
			else if (`time'<60) local time = string(`time'*1000, "%tcss!s")
			else if (`time'<3600) local time = string(`time'*1000, "%tc+mm!m! SS!s")
			else if (`time'<24*3600) local time = string(`time'*1000, "%tc+hH!h! mm!m! SS!s")
			timer clear `toc'
			local time `" as result " `time'""'
		}

		if (`"`msg'"'!="") di as `color' `msg'`time'
		if ("`newline'"!="") di
	}
end



// -------------------------------------------------------------
// Faster alternative to -egen group-. MVs, IF, etc not allowed!
// -------------------------------------------------------------
program define GenerateID, sortpreserve
syntax varlist(numeric) , [REPLACE Generate(name)]

	assert ("`replace'"!="") + ("`generate'"!="") == 1
	// replace XOR generate, could also use -opts_exclusive -
	foreach var of varlist `varlist' {
		assert !missing(`var')
	}

	local numvars : word count `varlist'
	if ("`replace'"!="") assert `numvars'==1 // Can't replace more than one var!
	
	// Create ID
	tempvar new_id
	sort `varlist'
	by `varlist': gen long `new_id' = (_n==1)
	qui replace `new_id' = sum(`new_id')
	qui compress `new_id'
	assert !missing(`new_id')
	
	local name = "i." + subinstr("`varlist'", " ", "#i.", .)
	char `new_id'[name] `name'
	la var `new_id' "[ID] `name'"

	// Either replace or generate
	if ("`replace'"!="") {
		drop `varlist'
		rename `new_id' `varlist'
	}
	else {
		rename `new_id' `generate'
	}

end

