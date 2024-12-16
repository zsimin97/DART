#!/bin/csh

#taurandom_file="taurandom.txt"
#while IFS = read -r taurandom

#set i=0
#for line in`cat taurandom.txt` 

#do 
#   account=$line
#   taurandom[$i]=$account
#done <"$taurandom_file"

set taurandom = (1.9839 1.7583 1.7396 2.0175 1.5391 1.8393 1.8670 1.6513 1.7431 1.4668 1.4704 1.7210 1.8445 2.2171 1.5666 1.7375 1.6835 1.3134 1.6122 1.3411 1.8681 1.5224 1.7200 1.5911 1.7607 1.5799 1.7980 1.8479 2.0424 1.6612 1.2723 1.5321 1.9709 1.4856 1.8922 1.7248 1.9873 1.3078 1.6605 1.4584)

@ inst = 1
while ($inst <= 40)

   # following the CESM strategy for 'inst_string'
   set inst_string = `printf _%04d $inst`
   set inst_string2 = `printf %04d $inst`

   # ===========================================================================
   set fname = "user_nl_cam${inst_string}"
   # ===========================================================================
   # ATM Namelist

   # DART/CAM requires surface geopotential (PHIS) for calculation of 
   # column pressures.  It's convenient to write it to the .h0. every
   # assimilation time. If you want to write it to a different .h?. file, you MUST
   # modify the assimilate.csh script in several places. You will need to set
   # 'empty_htapes = .false.' and change 'nhtfrq' and 'mfilt' to get a CAM
   # default-looking .h0. file.
   # If you want other fields written to history files, use h1,...,
   # which are not purged by assimilate.csh.
   #
   # inithist   'ENDOFRUN' ensures that CAM writes the required initial file
   #            every time it stops.
   # mfilt      # of times/history file.   Default values are 1,30,30,.....

   echo " inithist      = 'ENDOFRUN'"                     >! ${fname}
   echo " ncdata        = 'cam_initial${inst_string}.nc'" >> ${fname}
   echo " empty_htapes  = .true. "                        >> ${fname}
   echo " fincl1        = 'PHIS:I' "                      >> ${fname}
   echo "  fincl2        = 'PS', 'Z3', 'T', 'U', 'V', 'OMEGA', 'ELECDEN','WACCM_WI','ElecColDens'  " >> ${fname}
   echo " fincl3 = 'PS'" >> $fname
   echo " fincl4 = 'PS'" >> $fname
   echo " fincl5 = 'PS'" >> $fname
   echo "  nhtfrq        = -1,-1,-1,-1,-1 "                  >> ${fname}
   echo "  mfilt         = 1, 1,1,1,1 "                           >> ${fname}
   echo "  avgflag_pertape = 'A',  'I','I','I','I' " >> ${fname}
   echo " qbo_cyclic = .false." >> ${fname}
   echo " qbo_use_forcing = .false." >> ${fname}
   echo " fv_div24del2flag = 42" >> ${fname}
   echo " fv_nsplit = 256" >> ${fname}
   echo " fv_nspltrac = 128" >> ${fname}
   echo " fv_nspltvrm = 128" >> ${fname}
   echo "ionos_xport_nsplit = 10" >> ${fname}
   echo "dadadj_niter = 30" >> ${fname}
   echo " taubgnd =  ${taurandom[${inst}]}D-3 " >> ${fname} 
#   echo " solar_parms_data_file = '/glade/u/home/nickp/dart/analysis/solar_data/spread_kp_f107/waxsolar_3hr_c161205.nc.${inst_string2}' " >>$fname

#   echo " solar_parms_data_file = '/glade/work/nickp/dart/waccmx_osse_recam.pre_jan_feb_2009.iono_assim/solar_data/wa_smed_quiet.nc.${inst_string2}'" >>$fname

#   cat $fname wi_pert_v2/wi_mult${inst_string}.dat >> tmp.txt
#   mv tmp.txt $fname
#   cat $fname night_flux_pert/night_flux${inst_string}.dat >> tmp.txt
#   mv tmp.txt $fname

   @ inst = $inst + 1
end
