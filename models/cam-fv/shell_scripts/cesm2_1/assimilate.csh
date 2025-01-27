#!/bin/csh
#
# DART software - Copyright UCAR. This open source software is provided
# by UCAR, "as is", without charge, subject to all terms of use at
# http://www.image.ucar.edu/DAReS/DART/DART_download
#
# DART $Id: assimilate.csh.template 12675 2018-06-18 17:12:21Z raeder@ucar.edu $

# This script is designed to interface cesm2_0_beta05 or later
# and $dart/rma_trunk v11###.

# See 'RMA' for places where there are questions about RMA,
# especially file naming.

#=========================================================================
# Block 0: Set command environment
#=========================================================================
# This block is an attempt to localize all the machine-specific
# changes to this script such that the same script can be used
# on multiple platforms. This will help us maintain the script.

echo "`date` -- BEGIN CAM_ASSIMILATE"
pwd

set nonomatch       # suppress "rm" warnings if wildcard does not match anything

setenv CASEROOT $1
# Python uses C indexing on loops; cycle = [0,....,$DATA_ASSIMILATION_CYCLES - 1]
# "Fix" that here, so the rest of the script isn't confusing.
@ cycle = $2 + 1

# Tag DART's state output with names using CESM's convention:  
#    ${case}.${scomp}[_$inst].${filetype}[.$dart_file].${date}.nc 
#    These should all be named with $scomp = "cam" to distinguish
#    them from the same output from other components in multi-component assims.
set scomp = "cam"

# In CESM1_4 xmlquery must be executed in $CASEROOT.
cd ${CASEROOT}
setenv CASE           $CASEROOT:t
setenv ensemble_size  `./xmlquery NINST_ATM     --value`
setenv CAM_DYCORE     `./xmlquery CAM_DYCORE    --value`
setenv EXEROOT        `./xmlquery EXEROOT       --value`
setenv RUNDIR         `./xmlquery RUNDIR        --value`
setenv archive        `./xmlquery DOUT_S_ROOT   --value`
setenv TOTALPES       `./xmlquery TOTALPES      --value`
setenv CONT_RUN       `./xmlquery CONTINUE_RUN  --value`
setenv DATA_ASSIMILATION_CYCLES        `./xmlquery DATA_ASSIMILATION_CYCLES --value`
cd $RUNDIR

# A switch to save all the inflation files
setenv save_all_inf TRUE
# A switch to signal how often to save the stages' ensemble members: NONE, RESTART_TIMES, ALL
# Mean and sd will always be saved.
setenv save_stages_freq RESTART_TIMES

#set BASEOBSDIR = /glade/p/hao/itmodel/chihting/nick_obs_all_iono_gold_icon/
#set BASEOBSDIR = /glade/p/hao/itmodel/nickp/dart_obs/hourly_obs_seq.updated/nick_obs_all_iono_gold_icon/
#set BASEOBSDIR = /glade/p/hao/itmodel/nickp/dart_obs/hourly_obs_seq.updated/nick_obs_all/
set BASEOBSDIR = /glade/work/zsimin/syn_obs/1.5

# ==============================================================================
# standard commands:
#
# Make sure that this script is using standard system commands
# instead of aliases defined by the user.
# If the standard commands are not in the location listed below,
# change the 'set' commands to use them.
# The FORCE options listed are required.
# The VERBOSE options are useful for debugging, but are optional because
# some systems don't like the -v option to any of the following.
# E.g. NCAR's "cheyenne".
# ==============================================================================

set nonomatch       # suppress "rm" warnings if wildcard does not match anything
set   MOVE = '/usr/bin/mv -f'
set   COPY = '/usr/bin/cp -f --preserve=timestamps'
set   LINK = '/usr/bin/ln -fs'
set   LIST = '/usr/bin/ls '
set REMOVE = '/usr/bin/rm -fr'

# If your shell commands don't like the -v option and you want copies to be echoed,
# set this to be TRUE.  Otherwise, it should be FALSE.
set MOVEV   = FALSE
set COPYV   = FALSE
set LINKV   = FALSE
set REMOVEV = FALSE

switch ($HOSTNAME)
   case ys*:
      # NCAR "yellowstone"
      set TASKS_PER_NODE = `echo $LSB_SUB_RES_REQ | sed -ne '/ptile/s#.*\[ptile=\([0-9][0-9]*\)]#\1#p'`
      setenv MP_DEBUG_NOTIMEOUT yes
      set  LAUNCHCMD = mpirun.lsf
      breaksw

   case ch*:
      # Kluge to make batch environment consistent with the login invironment,
      # where DART executables were built.  Not fixed as of 2018-1-25.
      #module switch mpt mpt/2.15
      # PBS_NUM_PPN unavailable for some reason, so set manually.  
      # set TASKS_PER_NODE = $PBS_NUM_PPN 
      set TASKS_PER_NODE = 36
      setenv MP_DEBUG_NOTIMEOUT yes
      set  LAUNCHCMD = mpiexec_mpt
      breaksw

   default:
      # NERSC "hopper"
      set LAUNCHCMD  = "aprun -n $TOTALPES"
      breaksw

endsw

#=========================================================================
# Block 1: Populate a run-time directory with the input needed to run DART.
#=========================================================================

echo "`date` -- BEGIN COPY BLOCK"

if (  -e   ${CASEROOT}/input.nml ) then
   # ${COPY} ${CASEROOT}/input.nml .
   # Put a pared down copy (no comments) of input.nml in this assimilate_cam directory.
   sed -e "/#/d;/^\!/d;/^[ ]*\!/d" \
       -e '1,1i\WARNING: Changes to this file will be ignored. \n Edit \$CASEROOT/input.nml instead.\n\n\n' \
       ${CASEROOT}/input.nml >! input.nml  || exit 20
else
   echo "ERROR ... DART required file ${CASEROOT}/input.nml not found ... ERROR"
   echo "ERROR ... DART required file ${CASEROOT}/input.nml not found ... ERROR"
   exit 21
endif

echo "`date` -- END COPY BLOCK"

# If possible, use the round-robin approach to deal out the tasks.

if ($?TASKS_PER_NODE) then
   if ($#TASKS_PER_NODE > 0) then
      ${MOVE} input.nml input.nml.$$
      sed -e "s#layout.*#layout = 2#" \
          -e "s#tasks_per_node.*#tasks_per_node = $TASKS_PER_NODE#" \
          input.nml.$$ >! input.nml || exit 30
      $REMOVE input.nml.$$
   endif
endif

#=========================================================================
# Block 2: Identify requested output stages, to warn about redundant output.
#=========================================================================
# 
set MYSTRING = `grep stages_to_write input.nml`
set MYSTRING = (`echo $MYSTRING | sed -e "s#[=,'\.]# #g"`)
set STAGE_input     = FALSE
set STAGE_forecast  = FALSE
set STAGE_preassim  = FALSE
set STAGE_postassim = FALSE
set STAGE_analysis  = FALSE
set STAGE_output    = FALSE
# Assemble lists of stages to write out, which are not the 'output' stage.
set stages_except_output = "{"
@ stage = 2
while ($stage <= $#MYSTRING) 
   if ($MYSTRING[$stage] == 'input')  then
      set STAGE_input = TRUE
      if ($stage > 2) set stages_except_output = "${stages_except_output},"
      set stages_except_output = "${stages_except_output}input"
   endif
   if ($MYSTRING[$stage] == 'forecast')  then
      set STAGE_forecast = TRUE
      if ($stage > 2) set stages_except_output = "${stages_except_output},"
      set stages_except_output = "${stages_except_output}forecast"
   endif
   if ($MYSTRING[$stage] == 'preassim')  then
      set STAGE_preassim = TRUE
      if ($stage > 2) set stages_except_output = "${stages_except_output},"
      set stages_except_output = "${stages_except_output}preassim"
   endif
   if ($MYSTRING[$stage] == 'postassim') then
      set STAGE_postassim = TRUE
      if ($stage > 2) set stages_except_output = "${stages_except_output},"
      set stages_except_output = "${stages_except_output}postassim"
   endif
   if ($MYSTRING[$stage] == 'analysis')  then
      set STAGE_analysis = TRUE
      if ($stage > 2) set stages_except_output = "${stages_except_output},"
      set stages_except_output = "${stages_except_output}analysis"
   endif
   if ($stage == $#MYSTRING) then
      set stages_all = "${stages_except_output}"
      if ($MYSTRING[$stage] == 'output')  then
         set STAGE_output = TRUE
         set stages_all = "${stages_all},output"
      endif
   endif
   @ stage++
end
# Add the closing }
set stages_all = "${stages_all}}"
set stages_except_output = "${stages_except_output}}"
# Checking
echo "stages_except_output = $stages_except_output"
echo "stages_all = $stages_all"
if ($STAGE_output != TRUE) then
   echo "ERROR: assimilate.csh requires that input.nml:filter_nml:stages_to_write includes stage 'output'"
   exit 40
endif

#=========================================================================
# Block 3: Preliminary clean up, which can run in the background.
#=========================================================================
# CESM2_0's new archiver has a mechanism for removing restart file sets,
# which we don't need, but it runs only after the (multicycle) job finishes.  
# We'd like to remove unneeded restarts as the job progresses, allowing more
# cycles to run before needing to stop to archive data.  So clean them out of
# RUNDIR, and st_archive will never have to deal with them.
#-------------------------------------------------------------------------

# Move any hidden restart sets back into the run directory so they can be used or purged.
$LIST -d ../Hide*
if ($status == 0) then
   echo 'Moving files from ../Hide* to $rundir'
   $MOVE ../Hide*/* .
   rmdir ../Hide*
endif

# Cwd is currently RUNDIR.
set log_list = `$LIST -t cesm.log.*`
echo "log_list is $log_list"

# For safety, leave the most recent *2* restart sets in place.
# Prevents catastrophe if the last restart set is partially written before a crash.
# Add 1 more because the restart set used to start this will be counted:
# there will be 3 restarts when there are only 2 cesm.log files,
# which caused all the files to be deleted.
if ($#log_list >= 3) then

   # List of potential restart sets to remove
   set re_list = `$LIST -t *cpl.r.*`
   # Multi-driver creates a cpl.r file for each instance.
   if ($#re_list == 0) set re_list = `$LIST -t *cpl_0001.r.*`
   if ($#re_list < 3) then
      echo "Too many $#log_list cesm.log files for the $#re_list restart sets."
      echo "    Clean out the cesm.log files from failed cycles."
      exit 50
   endif
   # Member restarts to remove
   set rm_date = `echo $re_list[3] | sed -e "s/-/ /g;s/\./ /g;"`
   @ day = $#rm_date - 2
   @ sec = $#rm_date - 1
   set day_o_month = $rm_date[$day]
   set sec_o_day   = $rm_date[$sec]
   set day_time = ${day_o_month}-${sec_o_day}

   # Identify log files to be removed or moved.
   # [3] means the 3rd oldest restart set is being (re)moved.
   set rm_log = `echo $log_list[3] | sed -e "s/\./ /g;"`
   set rm_slot = $#rm_log
   if ($rm_log[$#rm_log] == 'gz') @ rm_slot--
   echo '$rm_log['$rm_slot']='$rm_log[$rm_slot]

   if ( $sec_o_day !~ '00000' || \
       ($sec_o_day =~ '00000' && $day_o_month % 1 != 0) ) then
      echo "Removing unneeded restart file set from RUNDIR: "
      echo "    ${CASE}"'*.{r,rs,rs1,rh0,h0,i}.*'${day_time}
      # Optionally save inflation restarts, even if it's not a 'save restart' time.
      if ($save_all_inf =~ TRUE) $MOVE ${CASE}*inf*${day_time}*  ${archive}/esp/hist

      # Remove intermediate member restarts,
      # but not DART means, sd, obs_seq, inflation restarts output.
      # Note that *cpl.ha.* is retained, and any h#, #>0.
      #          CASE                         DD-SSSSS
      $REMOVE  ${CASE}*.{r,rs,rs1,rh0,h0}.*${day_time}* &
      # Handle .i. separately to avoid sweeping up .{in,out}put_{mean,sd,...} files.
      $REMOVE ${CASE}*.i.[^io]*${day_time}*  &

      if ($save_stages_freq =~ NONE || $save_stages_freq =~ RESTART_TIMES) then
         # Checking
         if ($REMOVEV == "FALSE") \
            echo 'Removing  ${CASE}.*[0-9].${stages_except_output}*${day_time}*'
         # 'output' will have been renamed by the time the purging happens.
         $REMOVE  ${CASE}.*[0-9].${stages_except_output}*${day_time}* &
      endif
   else
      # Optionally COPY inflation restarts to the same place as the other inflation restarts.
      if ($save_all_inf =~ TRUE) then
#         if ($COPY == "FALSE") \
#            echo 'Copying ${CASE}*inf*${day_time}*  ${archive}/esp/hist '
         $COPY            ${CASE}*inf*${day_time}*  ${archive}/esp/hist
      endif

      # Optionally REMOVE stages' ensemble members (not means and sds).
      if ($save_stages_freq =~ NONE ) then
         # Checking
         if ($REMOVEV == "FALSE") \
            echo 'Removing at archive time ${CASE}.*[0-9].${stages_except_output}*${day_time}*'
         $REMOVE  ${CASE}.*[0-9].${stages_except_output}*${day_time}* &
      endif

      # Save the restart set to archive/rest/$datename, 
      # where it will be safe from removes of $component/rest.
      set save_date = `echo $re_list[3] | sed -e "s/\./ /g;"`
      @ piece = $#save_date - 1
      set save_root = ${archive}/rest/${save_date[$piece]}
      if (! -d $save_root) then
         mkdir -p $save_root
         if ($MOVEV == "FALSE") echo "Moving restart to $save_root"
         $MOVE ${CASE}*.{r,rs,rs1,rh0,h0}.*${day_time}*  $save_root &
         # Handle .i. separately to avoid sweeping up .{in,out}put_{mean,sd,...} files.
         $MOVE ${CASE}*.i.[^io]*${day_time}*             $save_root &
         $COPY *.output*inf*${day_time}*                 $save_root &
         # Save a few log files
         echo "Moving logs to $save_root"
         $MOVE *0001*${rm_log[$rm_slot]}*                $save_root &

      else
         echo "$save_root already exists.  Not archiving restart there."
      endif
   endif
   # Remove log files: *YYMMDD-HHMMSS*.  Except not da.log files
   $REMOVE  [^d]*${rm_log[$rm_slot]}*  &

   # I'd like to remove the CAM .r. files, since we always use the .i. files to do a hybrid start,
   # but apparently CESM needs them to be there, even though it doesn't read fields from them.
   # $REMOVE  ${CASE}.cam*.r.*${day_time}.nc &


endif


#=========================================================================
# Block 4: Determine time of model state 
#=========================================================================
# ... from file name of first member
# of the form "./${CASE}.cam_${ensemble_member}.i.2000-01-06-00000.nc"
#
# Piping stuff through 'bc' strips off any preceeding zeros.
#-------------------------------------------------------------------------

set FILE = `head -n 1 rpointer.atm_0001`
set FILE = $FILE:r
set ATM_DATE_EXT = `echo $FILE:e`
set ATM_DATE     = `echo $FILE:e | sed -e "s#-# #g"`
set ATM_YEAR     = `echo $ATM_DATE[1] | bc`
set ATM_MONTH    = `echo $ATM_DATE[2] | bc`
set ATM_DAY      = `echo $ATM_DATE[3] | bc`
set ATM_SECONDS  = `echo $ATM_DATE[4] | bc`
set ATM_HOUR     = `echo $ATM_DATE[4] / 3600 | bc`

echo "valid time of model is $ATM_YEAR $ATM_MONTH $ATM_DAY $ATM_SECONDS (seconds)"
echo "valid time of model is $ATM_YEAR $ATM_MONTH $ATM_DAY $ATM_HOUR (hours)"

#-----------------------------------------------------------------------------
# Get observation sequence file ... or die right away.
# The observation file names have a time that matches the stopping time of CAM.
#-----------------------------------------------------------------------------
# Make sure the file name structure matches the obs you will be using.
# PERFECT model obs output appends .perfect to the filenames

set YYYYMM   = `printf %04d%02d                ${ATM_YEAR} ${ATM_MONTH}`
#set OBSFNAME = `printf obs_seq.LA+S+A+COSMIC+GOLD+ICON+GNDTEC-WXGRD_%04d%02d%02d%02d ${ATM_YEAR} ${ATM_MONTH} ${ATM_DAY} ${ATM_HOUR}`
set OBSFNAME = `printf cam_obs_seq.%04d-%02d-%02d-%05d.perfect ${ATM_YEAR} ${ATM_MONTH} ${ATM_DAY} ${ATM_SECONDS}`
#if (! -d ${BASEOBSDIR}/${YYYYMM}_6H_CESM) then
#   echo "CESM+DART requires 6 hourly obs_seq files in directories of the form YYYYMM_6H_CESM"
#   echo "The directory ${BASEOBSDIR}/${YYYYMM}_6H_CESM is not found.  Exiting"
#   exit 60
#endif
#set OBS_FILE = ${BASEOBSDIR}/${YYYYMM}_1H/${OBSFNAME}
set OBS_FILE = ${BASEOBSDIR}/${OBSFNAME}

echo "OBS_FILE = $OBS_FILE"

if (  -e   ${OBS_FILE} ) then
   if ($LINKV == FALSE ) \
      echo "Linking $OBS_FILE obs_seq.out"
   $LINK            $OBS_FILE obs_seq.out
else
   echo "ERROR ... no observation file $OBS_FILE"
   echo "ERROR ... no observation file $OBS_FILE"
   exit 70
endif

#=========================================================================
# Block 5: Stage the files needed for SAMPLING ERROR CORRECTION
#
# The sampling error correction is a lookup table.
# The tables were originally in the DART distribution, but should
# have been staged to $CASEROOT at setup time.
# RMA:
# There's a single file which has a table for each ensemble size 2,...,100
# It is only needed if
# input.nml:&assim_tools_nml:sampling_error_correction = .true.,
# which is the default.
#=========================================================================

set  MYSTRING = `grep sampling_error_correction input.nml`
set  MYSTRING = `echo $MYSTRING | sed -e "s#[=,'\.]# #g"`
set  MYSTRING = `echo $MYSTRING | sed -e 's#"# #g'`

#=========================================================================
# Block 6: DART INFLATION
# This block is only relevant if 'inflation' is turned on AND 
# inflation values change through time:
# filter_nml
#    inf_flavor(:)  = 2  (or 3 (or 4 for posterior))
#    inf_initial_from_restart    = .TRUE.
#    inf_sd_initial_from_restart = .TRUE.
#
# This block stages the files that contain the inflation values.
# The inflation files are essentially duplicates of the DART model state,
# which have names in the CESM style, something like 
#    ${case}.dart.rh.${scomp}_output_priorinf_{mean,sd}.YYYY-MM-DD-SSSSS.nc
# The strategy is to use the latest such files in $rundir.
# If those don't exist at the start of an assimilation, 
# this block creates them with 'fill_inflation_restart'.
# If they don't exist AFTER the first cycle, the script will exit
# because they should have been available from a previous cycle.
# The script does NOT check the model date of the files for consistency
# with the current forecast time, so check that the inflation mean
# files are evolving as expected.
#
# CESM's st_archive should archive the inflation restart files
# like any other "restart history" (.rh.) files; copying the latest files
# to the archive directory, and moving all of the older ones.

#=========================================================================

set  MYSTRING = `grep inf_flavor input.nml`
set  MYSTRING = `echo $MYSTRING | sed -e "s#[=,'\.]# #g"`
set  PRIOR_INF = $MYSTRING[2]
set  POSTE_INF = $MYSTRING[3]

set  MYSTRING = `grep inf_initial_from_restart input.nml`
set  MYSTRING = `echo $MYSTRING | sed -e "s#[=,'\.]# #g"`
set  PRIOR_TF = `echo $MYSTRING[2] | tr '[:upper:]' '[:lower:]'`
set  POSTE_TF = `echo $MYSTRING[3] | tr '[:upper:]' '[:lower:]'`

if ($PRIOR_TF == FALSE ) then
   set stages_requested = 0
   if ( $STAGE_input    == TRUE ) @ stages_requested++
   if ( $STAGE_forecast == TRUE ) @ stages_requested++ 
   if ( $STAGE_preassim == TRUE ) @ stages_requested++
   if ( $stages_requested > 1 ) then
      echo " "
      echo "WARNING ! ! Redundant output is requested at multiple stages before assimilation."
      echo "            Stages 'input' and 'forecast' are always redundant."
      echo "            Prior inflation is OFF, so stage 'preassim' is also redundant. "
      echo "            We recommend requesting just 'preassim'."
      echo " "
   endif
endif
if ($POSTE_TF == FALSE ) then
   set stages_requested = 0
   if ( $STAGE_postassim == TRUE ) @ stages_requested++
   if ( $STAGE_analysis  == TRUE ) @ stages_requested++ 
   if ( $STAGE_output     == TRUE ) @ stages_requested++
   if ( $stages_requested > 1 ) then
      echo " "
      echo "WARNING ! ! Redundant output is requested at multiple stages after assimilation."
      echo "            Stages 'output' and 'analysis' are always redundant."
      echo "            Posterior inflation is OFF, so stage 'postassim' is also redundant. "
      echo "            We recommend requesting just 'output'."
      echo " "
   endif
endif

# CAM:static_init_model() always needs a caminput.nc and a cam_phis.nc
# for geometry information, etc.

set MYSTRING = `grep cam_template_filename input.nml`
set MYSTRING = `echo $MYSTRING | sed -e "s#[=,']# #g"`
set CAMINPUT = $MYSTRING[2]
$LINK ${CASE}.cam_0001.i.${ATM_DATE_EXT}.nc $CAMINPUT

# All of the .h0. files contain the same PHIS field, so we can link to any of them.

set hists = `$LIST ${CASE}.cam_0001.h0.*.nc`
set MYSTRING = `grep cam_phis_filename input.nml`
set MYSTRING = `echo $MYSTRING | sed -e "s#[=,']# #g"`
$LINK $hists[1] $MYSTRING[2]

# IFF we want PRIOR inflation:

if ( $PRIOR_INF > 0 ) then

   if ($PRIOR_TF == false) then
      # we are not using an existing inflation file.
      echo "inf_flavor(1) = $PRIOR_INF, using namelist values."

   else
      # Look for the output from the previous assimilation (or fill_inflation_restart)
      # RMA; file 'type' output_priorinf is hardwired according to DART2.0 naming convention.
      # Yes, we want the 'output' or 'postassim' version of the prior inflation,
      # because the 'preassim' version has not been updated by this cycle's assimilation.

      # If inflation files exists, use them as input for this assimilation
      # Must be separate commands because the 'order' that means and sds 
      # are finished being written out varies from cycle to cycle.
      # Leaving $CASE off of these $LIST allows it to find inflation files from ref_case.
      ($LIST -rt1 *.dart.rh.${scomp}_output_priorinf_mean* | tail -n 1 >! latestfile) > & /dev/null
      ($LIST -rt1 *.dart.rh.${scomp}_output_priorinf_sd*   | tail -n 1 >> latestfile) > & /dev/null
      set nfiles = `cat latestfile | wc -l`
      if ( $nfiles > 0 ) then
         set latest_mean = `head -n 1 latestfile`
         set latest_sd   = `tail -n 1 latestfile`
         # Need to COPY instead of link because of short-term archiver and disk management.
         ${COPY} $latest_mean input_priorinf_mean.nc
         ${COPY} $latest_sd   input_priorinf_sd.nc
      else if ($CONT_RUN == FALSE) then
         # It's the first assimilation; try to find some inflation restart files
         # or make them using fill_inflation_restart.
         # Fill_inflation_restart needs caminput.nc and cam_phis.nc for static_model_init,
         # so this staging is done in assimilate.csh (after a forecast) instead of stage_cesm_files.
   
         if (-x ${EXEROOT}/fill_inflation_restart) then
            # Create the inflation restart files.
            ${EXEROOT}/fill_inflation_restart
         else
            echo "ERROR: Requested PRIOR inflation restart for the first cycle, "
            echo "       but there are no files available "
            echo "       and fill_inflation_restart is missing from cam-fv/work."
            echo "EXITING"
            exit 85
         endif

      else
         echo "ERROR: Requested PRIOR inflation restart, "
         echo '       but files *.dart.rh.${scomp}_output_priorinf_* do not exist in the $rundir.'
         echo '       If you are changing from cam_no_assimilate.csh to assimilate.csh,'
         echo '       you might be able to continue by changing CONTINUE_RUN = FALSE for this cycle,'
         echo '       and restaging the initial ensemble.'
         $LIST -l *inf*
         echo "EXITING"
         exit 90
      endif

   endif
else
   echo "Prior Inflation           not requested for this assimilation."
endif

# POSTERIOR: We look for the 'newest' and use it - IFF we need it.

if ( $POSTE_INF > 0 ) then

   if ($POSTE_TF == false) then
      # we are not using an existing inflation file.
      echo "inf_flavor(2) = $POSTE_INF, using namelist values."

   else
      # Look for the output from the previous assimilation (or fill_inflation_restart).
      # (The only stage after posterior inflation.)
      ($LIST -rt1 *.dart.rh.${scomp}_output_postinf_mean* | tail -n 1 >! latestfile) > & /dev/null
      ($LIST -rt1 *.dart.rh.${scomp}_output_postinf_sd*   | tail -n 1 >> latestfile) > & /dev/null
      set nfiles = `cat latestfile | wc -l`

      # If one exists, use it as input for this assimilation
      if ( $nfiles > 0 ) then
         set latest_mean = `head -n 1 latestfile`
         set latest_sd   = `tail -n 1 latestfile`
         $LINK $latest_mean input_postinf_mean.nc
         $LINK $latest_sd   input_postinf_sd.nc
      else if ($CONT_RUN == FALSE) then
         # It's the first assimilation; try to find some inflation restart files
         # or make them using fill_inflation_restart.
         # Fill_inflation_restart needs caminput.nc and cam_phis.nc for static_model_init,
         # so this staging is done in assimilate.csh (after a forecast) instead of stage_cesm_files.
   
         if (-x ${EXEROOT}/fill_inflation_restart) then
            # Create the inflation restart files.
            ${EXEROOT}/fill_inflation_restart
         else
            echo "ERROR: Requested POSTERIOR inflation restart for the first cycle, "
            echo "       but there are no files available "
            echo "       and fill_inflation_restart is missing from cam-fv/work."
            echo "EXITING"
            exit 95
         endif

      else
         echo "ERROR: Requested POSTERIOR inflation restart, " 
         echo '       but files *.dart.rh.${scomp}_output_postinf_* do not exist in the $rundir.'
         $LIST -l *inf*
         echo "EXITING"
         exit 100
      endif
   endif
else
   echo "Posterior Inflation       not requested for this assimilation."
endif

#=========================================================================
# Block 7: Actually run the assimilation. 

# DART namelist settings required:
# &filter_nml           
#    adv_ens_command         = "no_CESM_advance_script",
#    obs_sequence_in_name    = 'obs_seq.out'
#    obs_sequence_out_name   = 'obs_seq.final'
#    single_file_in          = .false.,
#    single_file_out         = .false.,
#    stages_to_write         = stages you want + ,'output'
#    input_state_file_list   = 'cam_init_files'
#    output_state_file_list  = 'cam_init_files',

# WARNING: the default mode of this script assumes that 
#             input_state_file_list = output_state_file_list,
#          so the CAM initial files used as input to filter will be overwritten.
#          The input model states can be preserved by requesting that stage 'forecast'
#          be output.

#=========================================================================

# In the default mode of CAM assimilations, filter gets the model state(s) 
# from CAM initial files.  This section puts the names of those files into a text file.
# The name of the text file is provided to filter in filter_nml:input_state_file_list.

# NOTE: 
# If the files in input_state_file_list are CESM initial files (all vars and 
# all meta data), then they will end up with a different structure than 
# the non-'output', stage output written by filter ('preassim', 'postassim', etc.).  
# This can be prevented (at the cost of more disk space) by copying 
# the CESM format initial files into the names filter will use for preassim, etc.:
#    > cp $case.cam_0001.i.$date.nc  preassim_member_0001.nc.  
#    > ... for all members
# Filter will replace the state variables in preassim_member* with updated versions, 
# but leave the other variables and all metadata unchanged.

# If filter will create an ensemble from a single state,
#    filter_nml: perturb_from_single_instance = .true.
# it's fine (and convenient) to put the whole list of files in input_state_file_list.  
# Filter will just use the first as the base to perturb.

set line = `grep input_state_file_list input.nml | sed -e "s#[=,'\.]# #g"`
echo "$line"
set input_file_list = $line[2]

$LIST -1 ${CASE}.cam_[0-9][0-9][0-9][0-9].i.${ATM_DATE_EXT}.nc >! $input_file_list

# NMP update the O+ in the initial file from MMR to EDENS
module load nco
#@ i = 1
#while ($i <= 40)
#  set inst_string = `printf %04d $i`
#  set h1_file = ${CASE}.cam_${inst_string}.h1.${ATM_DATE_EXT}.nc
#  set init_file = ${CASE}.cam_${inst_string}.i.${ATM_DATE_EXT}.nc
##  # extract only O+
#  ncks  -O -v EDens $h1_file tmp_h1.nc
#  # convert to double (from float)
#  ncap2 -O -s 'EDens = double(EDens)' tmp_h1.nc tmp_h2.nc
##  # remove Op from initial file
##  # combine Op from h1 into tmp_init.nc
#   ncks -A -v EDens tmp_h2.nc $init_file
#   rm tmp_h1.nc tmp_h2.nc
#  @ i = $i + 1
#end


# If the file names in $output_state_file_list = names in $input_state_file_list,
# then the restart file contents will be overwritten with the states updated by DART.
# This is the behavior from DART1.0.
set line = `grep output_state_file_list input.nml | sed -e "s#[=,'\.]# #g"` 
set output_file_list = $line[2]

if ($input_file_list != $output_file_list) then
   echo "ERROR: assimilate.csh requires that input_file_list = output_file_list"
   echo "       You can probably find the data you want in stage 'forecast'."
   echo "       If you truly require separate copies of CAM's initial files"
   echo "       before and after the assimilation, see revision 12603, and note that"
   echo "       it requires changing the linking to cam_initial_####.nc, below."
   exit 105
endif

echo "`date` -- BEGIN FILTER"
${LAUNCHCMD} ${EXEROOT}/filter || exit 110
echo "`date` -- END FILTER"

#========================================================================
# Block 8: Rename the output using the CESM file-naming convention.
#=========================================================================

# If output_state_file_list is filled with custom (CESM) filenames,
# then 'output' ensemble members will not appear with filter's default,
# hard-wired names.  But file types output_{mean,sd} will appear and be
# renamed here.

# RMA; we don't know the exact set of files which will be written,
# so loop over all possibilities.

# Handle files with instance numbers first.
foreach FILE (`$LIST ${stages_all}_member_*.nc`)
   # split off the .nc
   set parts = `echo $FILE | sed -e "s#\.# #g"`
   # separate the pieces of the remainder
   set list = `echo $parts[1]  | sed -e "s#_# #g"`
   # grab all but the trailing 'member' and #### parts.
   @ last = $#list - 2
   # and join them back together
   set dart_file = `echo $list[1-$last] | sed -e "s# #_#g"`

   set type = "e"
   echo $FILE | grep "put"
   if ($status == 0) set type = "i"

   if ($MOVEV == FALSE) \
      echo "moving $FILE ${CASE}.${scomp}_$list[$#list].${type}.${dart_file}.${ATM_DATE_EXT}.nc"
   $MOVE           $FILE ${CASE}.${scomp}_$list[$#list].${type}.${dart_file}.${ATM_DATE_EXT}.nc
end

# Files without instance numbers need to have the scomp part of their names = "dart".
# This is because in st_archive, all files with  scomp = "cam"
# (= compname in env_archive.xml) will be st_archived using a pattern 
# which has the instance number added onto it.  {mean,sd} files don't instance numbers, 
# so they need to be archived by the "dart" section of env_archive.xml.
# But they still need to be different for each component, so include $scomp in the 
# ".dart_file" part of the file name.  Somewhat awkward and inconsistent, but effective.

# Means and standard deviation files (except for inflation).
foreach FILE (`$LIST ${stages_all}_{mean,sd}*.nc`)
   set parts = `echo $FILE | sed -e "s#\.# #g"`

   set type = "e"
   echo $FILE | grep "put"
   #if ($status == 0) set type = "i"

   if ($MOVEV == FALSE ) \
      echo "moving $FILE ${CASE}.dart.${type}.${scomp}_$parts[1].${ATM_DATE_EXT}.nc"
   $MOVE           $FILE ${CASE}.dart.${type}.${scomp}_$parts[1].${ATM_DATE_EXT}.nc
end

# Rename the observation file and run-time output

if ($MOVEV == FALSE ) \
   echo "Renaming obs_seq.final ${CASE}.dart.e.${scomp}_obs_seq_final.${ATM_DATE_EXT}"
${MOVE}           obs_seq.final ${CASE}.dart.e.${scomp}_obs_seq_final.${ATM_DATE_EXT}

if ($MOVEV == FALSE ) \
   echo "Renaming dart_log.out  ${scomp}_dart_log.${ATM_DATE_EXT}.out"
${MOVE}           dart_log.out  ${scomp}_dart_log.${ATM_DATE_EXT}.out

# Rename the inflation files

# Accommodate any possible inflation files.
# The .${scomp}_ part is needed by DART to distinguish
# between inflation files from separate components in coupled assims.

foreach FILE ( `$LIST ${stages_all}_{prior,post}inf_*`)
   set parts = `echo $FILE | sed -e "s#\.# #g"`
   if ($MOVEV == FALSE ) \
      echo "Moved $FILE  $CASE.dart.rh.${scomp}_$parts[1].${ATM_DATE_EXT}.nc"
   ${MOVE}        $FILE  $CASE.dart.rh.${scomp}_$parts[1].${ATM_DATE_EXT}.nc
end

# RMA; do these files have new names?
# Handle localization_diagnostics_files
set MYSTRING = `grep 'localization_diagnostics_file' input.nml`
set MYSTRING = `echo $MYSTRING | sed -e "s#[=,']# #g"`
set MYSTRING = `echo $MYSTRING | sed -e 's#"# #g'`
set loc_diag = $MYSTRING[2]
if (-f $loc_diag) then
   if ($MOVEV == FALSE ) \
      echo "Moving $loc_diag  ${scomp}_${loc_diag}.dart.e.${ATM_DATE_EXT}"
   $MOVE           $loc_diag  ${scomp}_${loc_diag}.dart.e.${ATM_DATE_EXT}
endif

# Handle regression diagnostics
set MYSTRING = `grep 'reg_diagnostics_file' input.nml`
set MYSTRING = `echo $MYSTRING | sed -e "s#[=,']# #g"`
set MYSTRING = `echo $MYSTRING | sed -e 's#"# #g'`
set reg_diag = $MYSTRING[2]
if (-f $reg_diag) then
   if ($MOVEV == FALSE ) \
      echo "Moving $reg_diag  ${scomp}_${reg_diag}.dart.e.${ATM_DATE_EXT}"
   $MOVE           $reg_diag  ${scomp}_${reg_diag}.dart.e.${ATM_DATE_EXT}
endif

# RMA
# Then this script will need to feed the files in output_restart_list_file
# to the next model advance.  
# This gets the .i. or .r. piece from the CESM format file name.
set line = `grep 0001 $output_file_list | sed -e "s#[\.]# #g"` 
set l = 1
while ($l < $#line)
   if ($line[$l] =~ ${scomp}_0001) then
      @ l++
      set file_type = $line[$l]
      break
   endif
   @ l++
end

set member = 1
while ( ${member} <= ${ensemble_size} )

   set inst_string = `printf _%04d $member`
   set ATM_INITIAL_FILENAME = ${CASE}.${scomp}${inst_string}.${file_type}.${ATM_DATE_EXT}.nc

   $LINK $ATM_INITIAL_FILENAME ${scomp}_initial${inst_string}.nc || exit 120

   @ member++

end

if ($cycle == $DATA_ASSIMILATION_CYCLES) then


   rm /glade/scratch/nickp/archive/${CASE}/atm/hist/*.preassim.*
   rm /glade/scratch/nickp/archive/${CASE}/atm/hist/*.i.*
   #rm /glade/p/hao/itmodel/nickp/archive/${CASE}/atm/hist/*.preassim.*
   #rm /glade/p/hao/itmodel/nickp/archive/${CASE}/atm/hist/*.i.*


   if ($#log_list >= 3) then
      # During the last cycle, hide the 2nd newest restart set 
      # so that it's not archived, but is available for debugging.
      # This is assuming that DATA_ASSIMILATION_CYCLES has not been changed in env_run.xml
      # since the start (not submission) of this job.
      # (Requested by Karspeck for coupled assims, which need to keep 4 atmospheric
      #  cycles for each ocean cycle.)
      set hide_date = `echo $re_list[2] | sed -e "s/-/ /g;s/\./ /g;"`
      @ day = $#hide_date - 2
      @ sec = $#hide_date - 1
      set day_o_month = $hide_date[$day] 
      set sec_o_day   = $hide_date[$sec]
      set day_time = ${day_o_month}-${sec_o_day}
      set hidedir = ../Hide_${day_time}
      mkdir $hidedir
       
      if ($save_all_inf =~ TRUE) then
         # Optionally put the 2nd-to-last and last inflation restarts in the archive directory.
         # (to protect last from st_archive putting them in exp/hist)
         if ($MOVEV == FALSE ) \
            echo 'Hiding ${CASE}*${stages_except_output}*inf*  ${archive}/esp/rest'
         $MOVE           ${CASE}*${stages_except_output}*inf*  ${archive}/esp/rest
         # Don't need 2nd to last inf restarts now, but want them to be archived later.
         # COPY instead of LINK because they'll be moved or used later.
         # (This ignores output*inf of the current day+time, which is needed for the next cycle.
         $COPY ${CASE}*output*inf* ${archive}/esp/rest/
      else
         # output*inf must be copied back because it needs to be in rundir when st_archive runs
         # to save the results of the following assim (number $DATA_ASSIMILATION_CYCLES).
         if ($MOVEV == FALSE ) \
            echo 'Hiding  ${CASE}*inf*${day_time}*  $hidedir'
         $MOVE            ${CASE}*inf*${day_time}*  $hidedir
         # Don't need 2nd to last inf restarts now, but want them to be archived later.
         $COPY  $hidedir/${CASE}*output*inf*${day_time}* .
      endif
  
      # Hide the CAM 'restart' files from the previous cycle (day_time) from the archiver.
      if ($MOVEV == FALSE ) \
         echo 'Hiding ${CASE}*.{r,rs,rs1,rh0,h0,i}.*${day_time}*    $hidedir'
      $MOVE           ${CASE}*.{r,rs,rs1,rh0,h0,i}.*${day_time}*    $hidedir

      # Move log files: *YYMMDD-HHMMSS.  [2] means the 2nd newest restart set is being moved.
      set rm_log = `echo $log_list[2] | sed -e "s/\./ /g;"`
      # -1 skips the gz at the end of the names.
      set rm_slot = $#rm_log
      if ($rm_log[$#rm_log] =~ gz) @ rm_slot--
      if ($MOVEV == FALSE ) \
         echo "Hiding log files into $hidedir;"' $rm_log['$rm_slot']='$rm_log[$rm_slot]
      $MOVE  *$rm_log[$rm_slot]*  $hidedir
   endif

   # DEBUG st_archive by making a shadow copy of this directory.
   mkdir ../run_shadow
   foreach f (`ls`)
      $LIST -l $f > ../run_shadow/$f
   end

   # Create a DART restart file, which have only the name of inflation restart files in them.
   # This is needed in order to use the CESM st_archive mechanisms for keeping, in $rundir, 
   # files which are needed for restarts.
   # Inflation restart file names for all components will be in this one restart file,
   # since the inflation restart files have the component names in them.
   # The have suffix (file type) .rh. in their names.

#   set inf_list = `ls *output_{prior,post}inf_*.${ATM_DATE_EXT}.nc`
#   set file_list = 'restart_hist = "./'$inf_list[1]\"
#   set i = 2
#   while ($i <= $#inf_list)
#      set file_list = (${file_list}\, \"./$inf_list[$i]\")
#      @ i++
#   end
#   cat << ___EndOfText >! inf_restart_list.cdl
#       netcdf template {  // CDL file which ncgen will use to make a DART restart file
#                          // containing just the names of the needed inflation restart files.
#       dimensions:
#            num_files = $#inf_list;
#       variables:
#            string  restart_hist(num_files);
#            restart_hist:long_name = "DART restart history file names";
#       data:
#            $file_list;
#       }
#___EndOfText
#
#   switch ($HOSTNAME)
#      case ch*:
#         # These are needed after the /glade/p fix, in order to use ncgen 
#         # for inflation history restart file handling.
#         module load pnetcdf/1.8.0 netcdf-mpi/4.4.1.1
#   endsw
#   ncgen -k netCDF-4 -o ${CASE}.dart.r.${scomp}.${ATM_DATE_EXT}.nc inf_restart_list.cdl
#   if ($status == 0) $REMOVE inf_restart_list.cdl

   switch ($HOSTNAME)
      case ch*:
         module unload pnetcdf/1.8.0 netcdf-mpi/4.4.1.1
   endsw

endif   

echo "`date` -- END CAM_ASSIMILATE"

# Be sure that the removal of unneeded restart sets and copy of obs_seq.final are finished.
wait

exit 0

# <next few lines under version control, do not edit>
# $URL: https://svn-dares-dart.cgd.ucar.edu/DART/branches/recam/models/cam-fv/shell_scripts/cesm2_0/assimilate.csh.template $
# $Revision: 12675 $
# $Date: 2018-06-18 11:12:21 -0600 (Mon, 18 Jun 2018) $


