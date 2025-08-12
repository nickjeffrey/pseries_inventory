#!/usr/bin/perl -w



# CHANGE LOG
# ----------
# 2011/04/13	Nick	Script created
# 2012/06/08	Nick	Add column for LPAR ID
# 2012/06/08	Nick	Truncate RAM to 1 decimaal place
# 2012/06/08	Nick	Add oracle instances
# 2012/06/08	Nick	Significant code refactoring
# 2014/05/05	Nick	Sort output by LPAR name
# 2014/05/05	Nick	Add troubleshooting notes
# 2016/07/28	Nick	Add support for Linux LPARs
# 2025/08/12	Nick	Add @lpars_to_ignore array


# OUTSTANDING TASKS
# -----------------
#  1) add notes on how to add your ssh key to all the HMC's
#  2) remember to add the key to all HMC's
#  3) Check to see if the /usr/local/bin/db2ls file exists before trying to execute it
#  5) If there are multiple versions of DB2 installed, only the last line from the db2ls command will be shown in the report




# NOTES
# -----
#
# This script will connect to an HMC/IVM and gather assorted information, then generate an HTML report.
#
# This script is run daily from a cron job, so there will always be an up-to-date report of the pSeries
# resource availability on a web page.  An example cron entry is shown below:
#  50 23 * * * /usr/local/bin/pseries_inventory.pl > /var/www/html/pseries_inventory.html 2>&1	#generate POWER inventory report
#
# It is assumed that this script is being run by the "nagios" userid, just because that userid tends to already have SSH key pairs already set up everywhere.
#
# This script will ssh into an HMC/IVM to get the information from the managed system(s).  Since
# this script runs from a cron job, we need to setup password-less ssh logins to the HMC/IVM.  Here's how:
#    echo generate ssh keys on the UNIX box this script runs from
#    ssh-keygen -t dsa <ENTER><ENTER>
#    # now login to the HMC and run the following command:
#    mkauthkeys --add 'public key goes here'  
#   
#


# TROUBLESHOOTING
# ---------------
# 
#  The HMC only records the operating system version of each LPAR when the HMC boots.
#  So, if you perfom an in-place operating system upgrade on an LPAR, the HMC will have
#  stale information until the next HMC reboot.
#  HINT: Reboot the HMC after performing an in-place upgrade of AIX/Linux/i5OS 
#
#  The HMC may show "unknown" or "no information" for the OS version.
#  This can happen if the RMC daemons on the AIX LPAR are not running or have problems.
#  You should be able to fix this by rebuilding the RMC daemon on the AIX LPAR.  
#  Try these commands on the AIX LPAR:
#     stopsrc  -g rsct_rm 						# stop RSCT daemons
#     startsrc -g rsct_rm 						# start RSCT daemons
#  If the above two commands do not help, try these:
#     /usr/sbin/rsct/install/bin/recfgct -s				# cleanup config information for the node
#     /usr/sbin/rsct/bin/rmcctrl -z					# stop RSCT
#     test -e rm /var/ct/cfg/ct_has.thl && rm /var/ct/cfg/ct_has.thl	# Remove cluster security services trusted host list file
#     /usr/sbin/rsct/bin/rmcctrl -A					# start RSCT



use strict;					#enforce good coding practices
my (%pseries,$ssh,$community,$oid_memory,$oid_cpu,$cmd);
my ($disktotal,@vglist);
my (@hmc,$hmc,@ivm,$ivm,$verbose,$date,$key,$hmcuser,$ivmuser,$lpar,@lpars,@lpars_to_ignore);

#define variables
@hmc             = ("hmc1.example.com","hmc2.example.com");			#define all hardware management consoles
@ivm             = ("");				#define all integrated virtualization managers (ie IVM on a blade)
$hmc             = "";					#variable to hold current value of @hmc array
$ssh             = "/usr/bin/ssh";			#fully qualified path to ssh binary (determined later)
$hmcuser         = "hscroot";				#the userid on the HMC
$ivmuser         = "padmin";				#the userid on the IVM
$oid_memory      = ".1.3.6.1.2.1.25.2.2.0";		#SNMP OID for memory on LPAR
$oid_cpu         = ".1.3.6.1.4.1.2.3.1.2.2.2.1.18.32.0";	#SNMP OID for hundredths of a CPU entitled capacity on LPAR.  Divide by 100 to get physical CPUs entitlement
$community       = "public";				#SNMP community string
$verbose         = "no";				#enable this switch for debugging
$date            = `date`;  chomp $date;		#get the current date
@lpars_to_ignore = ("myboguslpar","lpar99","someotherlpar","yetanotherlpar");





sub sanity_checks {
   #
   # confirm required files exist
   #
   print "running sanity_checks \n" if ($verbose eq "yes");
   #
   $ssh = "/usr/local/bin/ssh" if (-e "/usr/local/bin/ssh");	#figure out where the ssh binary is located
   $ssh = "/usr/bin/ssh"       if (-e "/usr/bin/ssh");		#figure out where the ssh binary is located
   $ssh = "/bin/ssh"           if (-e "/bin/ssh");		#figure out where the ssh binary is located
   #
   unless ( -e $ssh ) {				#confirm ssh binary exists
      print "ERROR: Could not find $ssh \n";
      print "       Now exiting script \n\n";
      exit;   					#exit script
   }  						#end of unless block
   #
   unless ( -x $ssh ) {				#confirm ssh binary is executable
      print "ERROR: $ssh file is not executable \n";
      print "       Now exiting script \n\n";
      exit;   					#exit script
   }  						#end of unless block
}						#end of subroutine





sub get_pseries_serial_numbers {
   #
   # determine which hmc we can talk to and get list of managed system serial numbers
   #
   print "running get_pseries_serial_numbers \n" if ($verbose eq "yes");
   #
   foreach $hmc (@hmc) {
      next if ( $hmc eq "" );				#skip any blank array elements
      print "   connecting to HMC $hmc \n" if ($verbose eq "yes");
      open (IN, "$ssh $hmcuser\@$hmc lssyscfg -r sys |");
      while (<IN>) {
         if (/^name=(.*),type_model/){	#parse out the name of the managed pseries server
            $pseries{$1}{name}=$1;		#create key in hash
            print "   found managed system $pseries{$1}{name} \n" if ($verbose eq "yes");
            $pseries{$1}{ssh_userid} = "$hmcuser";	#figure out the appropriate userid for this HMC/IVM
            $pseries{$1}{ssh_mgmtconsole} = "$hmc";	#figure out the appropriate HMC/IVM that manages this POWER server
         }					#end of if block
      }					#end of while loop
      close IN;				#close filehandle
   }					#end of foreach loop
   #
   # Now the the same thing for any IVM's (which use a different userid)
   foreach $ivm (@ivm) {
      next if ( $ivm eq "" );				#skip any blank array elements
      print "   connecting to IVM $hmc \n" if ($verbose eq "yes");
      open (IN, "$ssh $ivmuser\@$ivm lssyscfg -r sys |");
      while (<IN>) {
         if (/^name=(.*),type_model/){	#parse out the name of the managed pseries server
            $pseries{$1}{name}=$1;		#create key in hash
            print "   found managed system $pseries{$1}{name} \n" if ($verbose eq "yes");
            $pseries{$1}{ssh_userid} = "$ivmuser";	#figure out the appropriate userid for this HMC/IVM
            $pseries{$1}{ssh_mgmtconsole} = "$ivm";	#figure out the appropriate HMC/IVM that manages this POWER server
         }					#end of if block
      }					#end of while loop
      close IN;				#close filehandle
   }					#end of foreach loop
}					#end of subroutine






sub get_pseries_cpu {
   #
   # figure out CPU amounts on each pSeries server
   #
   print "running get_pseries_cpu subroutine \n" if ($verbose eq "yes");
   #
   foreach $key (sort keys %pseries) {
      next if ( $pseries{$key}{name} eq "" );						#skip any blank array elements that may exist
      $pseries{$key}{configurable_proc_units}=0;					#initialize variable
      $pseries{$key}{curr_avail_sys_proc_units}=0;					#initialize variable
      $pseries{$key}{installed_sys_proc_units}=0;					#initialize variable
      open (IN, "$ssh $pseries{$key}{ssh_userid}\@$pseries{$key}{ssh_mgmtconsole} \"lshwres -m $pseries{$key}{name}  -r proc --level sys\" |");
      while (<IN>) {
         #
         # find CPU amounts
         #
         if (/configurable_sys_proc_units=([0-9\.]+),/){				#find amount of licensed cpu
            $pseries{$key}{configurable_sys_proc_units}=$1;				#assign value to hash
         }										#end of if block 
         if (/curr_avail_sys_proc_units=([0-9\.]+),/){					#find amount of unallocated (licensed) cpu
            $pseries{$key}{curr_avail_sys_proc_units}=$1; 				#assign value to hash
         }										#end of if block 
         if (/installed_sys_proc_units=([0-9\.]+),/){					#find total amount of installed cpu
            $pseries{$key}{installed_sys_proc_units}=$1; 				#assign value to hash
         }										#end of if block 
         #the HMC does not tell us the amount of cpu used by the LPARs, 
         #only the amount of FREE cpu.  Do a little math to figure out how
         #much cpu is actually being used.  Take the licensed cpu, 
         #then subtract the unallocated cpu.
         $pseries{$key}{used_sys_proc_units}=$pseries{$key}{configurable_sys_proc_units}-$pseries{$key}{curr_avail_sys_proc_units};
         print "   $pseries{$key}{name} configurable_sys_proc_units:$pseries{$key}{configurable_sys_proc_units} used_sys_proc_units:$pseries{$key}{used_sys_proc_units} usecurr_avail_sys_proc_units:$pseries{$key}{curr_avail_sys_proc_units} \n" if ($verbose eq "yes");
      }											#end of while loop
   }											#end of foreach block
   close IN;     									#close filehandle
}											#end of subroutine 



sub get_pseries_memory {
   #
   # figure out memory amounts on each pSeries server
   #
   print "running get_pseries_memory subroutine \n" if ($verbose eq "yes");
   #
   foreach $key (sort keys %pseries) {
      next if ( $pseries{$key} eq "" );                                               #skip any blank array elements that may exist
      $pseries{$key}{configurable_sys_mem}=0;                                         #initialize variable
      $pseries{$key}{curr_avail_sys_mem}=0;                                           #initialize variable
      $pseries{$key}{installed_sys_mem}=0;                                            #initialize variable
      $pseries{$key}{max_capacity_sys_mem}=0;                                         #initialize variable
      $pseries{$key}{sys_firmware_mem}=0;                                             #initialize variable
      #open (IN, "$ssh $hmcuser\@$hmc \"lshwres -m $pseries{$key}{name}  -r mem --level sys\" |");
      open (IN, "$ssh $pseries{$key}{ssh_userid}\@$pseries{$key}{ssh_mgmtconsole} \"lshwres -m $pseries{$key}{name}  -r mem --level sys\" |");
      while (<IN>) {
         #
         # find memory amounts
         #
         if (/configurable_sys_mem=([0-9]+),/){                                 		#find amount of licensed memory
            $pseries{$key}{configurable_sys_mem}=$1;                                  		#assign value to hash
            $pseries{$key}{configurable_sys_mem}=$pseries{$key}{configurable_sys_mem}/1024; 	#convert MB to GB
         }                                                                      		#end of if block
         if (/curr_avail_sys_mem=([0-9]+),/){                                   		#find amount of unallocated (licensed) memory
            $pseries{$key}{curr_avail_sys_mem}=$1;                                    		#assign value to hash
            $pseries{$key}{curr_avail_sys_mem}=$pseries{$key}{curr_avail_sys_mem}/1024;     	#convert MB to GB
         }                                                                      		#end of if block
         if (/installed_sys_mem=([0-9]+),/){                                    		#find total amount of installed memory
            $pseries{$key}{installed_sys_mem}=$1;                                     		#assign value to hash
            $pseries{$key}{installed_sys_mem}=$pseries{$key}{installed_sys_mem}/1024;       	#convert MB to GB
         }                                                                      		#end of if block
         if (/max_capacity_sys_mem=([0-9]+),/){                                 		#find maximum installable memory for this server
            $pseries{$key}{max_capacity_sys_mem}=$1;                                  		#assign value to hash
            $pseries{$key}{max_capacity_sys_mem}=$pseries{$key}{max_capacity_sys_mem}/1024; 	#convert MB to GB
         }                                                                      		#end of if block
         if (/sys_firmware_mem=([0-9]+),/){                                     		#find memory used by hypervisor
            $pseries{$key}{sys_firmware_mem}=$1;                                      		#assign value to hash
            $pseries{$key}{sys_firmware_mem}=$pseries{$key}{sys_firmware_mem}/1024;         	#convert MB to GB
         }                                                                      		#end of if block
         #the HMC does not tell us the amount of memory used by the LPARs,
         #only the amount of FREE memory.  Do a little math to figure out how
         #much memory is actually being used.  Take the licensed system
         #memory, then subtract the memory used by the hypervisor, then
         #subtract the unallocated memory.
         $pseries{$key}{used_sys_mem}=$pseries{$key}{configurable_sys_mem}-$pseries{$key}{curr_avail_sys_mem}-$pseries{$key}{sys_firmware_mem};
         print "   $pseries{$key}{name} configurable_sys_mem:$pseries{$key}{configurable_sys_mem} used_sys_mem:$pseries{$key}{used_sys_mem} curr_avail_sys_mem:$pseries{$key}{curr_avail_sys_mem} firmware_mem:$pseries{$key}{sys_firmware_mem} \n" if ($verbose eq "yes");
      }                                                                         #end of while loop
   }  										#end of foreach block
   close IN;                         						#close filehandle
}            									#end of subroutine






sub get_lpar_details {
   #
   # figure out details from each LPAR
   #
   print "running get_lpar_details subroutine \n" if ($verbose eq "yes");
   #
   #
   #
   foreach $key (sort keys %pseries) {						#loop through for each managed system
      #
      # ssh into the HMC/IVM and run the "lssyscfg" command with the "lpar" switch to get LPAR name/id
      #
      open (IN, "$ssh $pseries{$key}{ssh_userid}\@$pseries{$key}{ssh_mgmtconsole} \"lssyscfg -r lpar -m $pseries{$key}{name}\" |");
      while (<IN>) {
         #
         if (/^name=([a-zA-Z0-9_\-]+),/) {                                 	#find name of LPAR
            $lpar = $1;                             #assign value to hash
            $pseries{$key}{lpars}{$lpar}{name} = $lpar;                         #assign value to hash
            print "\n found LPAR name=$pseries{$key}{lpars}{$lpar}{name} " if ($verbose eq "yes");
            #
            # add some dummy values just in case SSH daemon is down for some LPARs, avoid undef errors
            $pseries{$key}{lpars}{$lpar}{curr_proc_units} = "";	
            $pseries{$key}{lpars}{$lpar}{cpu_speed}       = "";
            $pseries{$key}{lpars}{$lpar}{db2level}        = "";
            $pseries{$key}{lpars}{$lpar}{oracleinstance}  = "";	
            $pseries{$key}{lpars}{$lpar}{disktotal}       = "";		
         }                                                                      #end of if block
         if (/state=([a-zA-Z0-9_\- ]+),/) {                                 	#state of LPAR should be "Running" or "Not Activated"
            $pseries{$key}{lpars}{$lpar}{state} = $1;                            #assign value to hash
            print " state=$pseries{$key}{lpars}{$lpar}{state} " if ($verbose eq "yes");
         }                                                                      #end of if block
         if (/lpar_id=([0-9]+),/) {                                 		#numeric LPAR ID
            $pseries{$key}{lpars}{$lpar}{lpar_id} = $1;                         #assign value to hash
            print " ID=$pseries{$key}{lpars}{$lpar}{lpar_id} " if ($verbose eq "yes");
         }                                                                      #end of if block
         if (/os_version=([a-zA-Z0-9 \-\.]+),/) {                      		#operating system name and version number for AIX
            $pseries{$key}{lpars}{$lpar}{os_version} = $1;                      #assign value to hash
            print " OSversion=$pseries{$key}{lpars}{$lpar}{os_version} " if ($verbose eq "yes");
         }                                                                      #end of if block
         if (/os_version=(Linux[a-zA-Z0-9\-\.\/ ]+),/) {               		#operating system name and version number for Linux
            $pseries{$key}{lpars}{$lpar}{os_version} = $1;                      #assign value to hash
            print " OSversion=$pseries{$key}{lpars}{$lpar}{os_version} " if ($verbose eq "yes");
         }                                                                      #end of if block
         # check to see if this lpar is in the @lpars_to_ignore array
         $pseries{$key}{lpars}{$lpar}{ignore} = "no";                      	#assign default value to avoid undef error
         foreach my $ignore (@lpars_to_ignore) {
            if ($ignore eq $lpar) { 
               $pseries{$key}{lpars}{$lpar}{ignore} = "yes"; 
               print "   ignoring LPAR $lpar \n" if ($verbose eq "yes");
            }									#end of if block
         }									#end of foreach loop
      }										#end of while loop
      close IN; 								#close filehandle
      #
      #
      # ssh into the HMC/IVM and run the "lshwres" command to get current memory allocations for each LPAR
      #
      open (IN, "$ssh $pseries{$key}{ssh_userid}\@$pseries{$key}{ssh_mgmtconsole} \"lshwres -r mem --level lpar -m $pseries{$key}{name}\" |");
      while (<IN>) {
         #
         if (/lpar_name=([a-zA-Z0-9_\-]+),/) {                                 	#find name of LPAR (note that field is lpar_name instead of name)
            $lpar = $1;                             #assign value to hash
            $pseries{$key}{lpars}{$lpar}{name} = $lpar;                             #assign value to hash
            print "\nname=$pseries{$key}{lpars}{$lpar}{name} " if ($verbose eq "yes");
         }                                                                      #end of if block
         if (/curr_mem=([0-9]+),/) {         	                        	#find amount of memory in MB
            $pseries{$key}{lpars}{$lpar}{memory} = $1;                           #assign value to hash
            $pseries{$key}{lpars}{$lpar}{memory} = $pseries{$key}{lpars}{$lpar}{memory} / 1024; 		#convert MB to GB
            $pseries{$key}{lpars}{$lpar}{memory} = sprintf( "%.1f", $pseries{$key}{lpars}{$lpar}{memory} );	#truncate to 1 decimal place
            print "   memory=$pseries{$key}{lpars}{$lpar}{memory} " if ($verbose eq "yes");
         }                                                                      #end of if block
      }										#end of while loop
      close IN; 								#close filehandle
      #
      #
      # ssh into the HMC/IVM and run the "lshwres" command to get current CPU allocations for each LPAR
      #
      $pseries{$key}{lpars}{$lpar}{curr_proc_units} = 0;                  	#initialize to avoid undef errors
      open (IN, "$ssh $pseries{$key}{ssh_userid}\@$pseries{$key}{ssh_mgmtconsole} \"lshwres -r proc --level lpar -m $pseries{$key}{name}\" |");
      while (<IN>) {
         #
         if (/name=([a-zA-Z0-9_\-]+),/) {                                 	#find name of LPAR
            $lpar = $1;                             #assign value to hash
            $pseries{$key}{lpars}{$lpar}{name} = $lpar;                             #assign value to hash
            print "\n name=$pseries{$key}{lpars}{$lpar}{name} " if ($verbose eq "yes");
         }                                                                      #end of if block
         if (/curr_proc_units=([0-9\.]+),/) {         	                       	#find amount of processing units
            $pseries{$key}{lpars}{$lpar}{curr_proc_units} = $1;                  #assign value to hash
            $pseries{$key}{lpars}{$lpar}{curr_proc_units} = sprintf( "%.1f", $pseries{$key}{lpars}{$lpar}{curr_proc_units} );	#truncate to 1 decimal place
            print " CPU=$pseries{$key}{lpars}{$lpar}{curr_proc_units} " if ($verbose eq "yes");
         }                                                                      #end of if block
      }										#end of while loop
      close IN; 								#close filehandle
      #
      #
      #
      #
      # There are some items we cannot get from the HMC, so we will need to SSH into each LPAR to gather the info.
      #
      # ssh into the HMC/IVM just to get the names of all the LPARs
      open (IN, "$ssh $pseries{$key}{ssh_userid}\@$pseries{$key}{ssh_mgmtconsole} \"lssyscfg -r lpar -m $pseries{$key}{name}\" |");
      while (<IN>) {
         #
         if (/name=([a-zA-Z0-9_\-]+),/) {                                 	#find name of LPAR
            $lpar = $1;                             #assign value to hash
            $pseries{$key}{lpars}{$lpar}{name} = $lpar;                             #assign value to hash
            print "\n name=$pseries{$key}{lpars}{$lpar}{name} " if ($verbose eq "yes");
         }                                                                      #end of if block
         #
         #
         # Now that we know the names of all the LPARs, SSH into each one to gather information.
         #
         if ($pseries{$key}{lpars}{$lpar}{state} eq "Not Activated"){
            print "Skipping powered down LPAR $pseries{$key}{lpars}{$lpar}{name} \n" if ($verbose eq "yes");    	#skip LPARs that are powered down, as we will not be able to SSH into them
         }										#end of if block
         #
         if ( ($pseries{$key}{lpars}{$lpar}{state} eq "Running") && (($pseries{$key}{lpars}{$lpar}{ignore} eq "no")) ){				#confirm the LPAR is running before trying to SSH into it
         #if ($pseries{$key}{lpars}{$lpar}{state} eq "Running"){				#confirm the LPAR is running before trying to SSH into it
            #
            # Figure out if the LPAR is running AIX or Linux
            print "checking for AIX or Linux on $lpar " if ($verbose eq "yes");
            $pseries{$key}{lpars}{$lpar}{os} = `ssh $lpar uname`;
            chomp $pseries{$key}{lpars}{$lpar}{os};					#remove newline
            print "    OS=$pseries{$key}{lpars}{$lpar}{os} \n" if ($verbose eq "yes");
            #
            #
            # Get CPU speed for this this LPAR (it's really for the managed system)
            print "checking CPU speed on  $lpar " if ($verbose eq "yes");
            $cmd = "ssh $lpar lsattr -El proc0  | grep frequency | tr -s \" \" | cut -d \" \" -f 2"           if ($pseries{$key}{lpars}{$lpar}{os} eq "AIX");
            $cmd = "ssh $lpar cat /proc/cpuinfo | grep ^clock | uniq | cut  -d \" \" -f 2 | sed -e s'/MHz//'" if ($pseries{$key}{lpars}{$lpar}{os} eq "Linux");
            $pseries{$key}{lpars}{$lpar}{cpu_speed} = `$cmd`;
            chomp $pseries{$key}{lpars}{$lpar}{cpu_speed};				#remove newline
            #
            # AIX shows processor speed in hz, while Linux shows processor speed in Mhz.  Convert both to Ghz.
            if ( $pseries{$key}{lpars}{$lpar}{os} eq "AIX" ) {				#convert hz to Ghz
               $pseries{$key}{lpars}{$lpar}{cpu_speed} = $pseries{$key}{lpars}{$lpar}{cpu_speed} / 1000 / 1000 / 1000;	
            } 											
            if ( $pseries{$key}{lpars}{$lpar}{os} eq "Linux" ) {				#convert Mhz to Ghz
               $pseries{$key}{lpars}{$lpar}{cpu_speed} = $pseries{$key}{lpars}{$lpar}{cpu_speed} / 1000;	
            } 											
            $pseries{$key}{lpars}{$lpar}{cpu_speed} = sprintf( "%.1f", $pseries{$key}{lpars}{$lpar}{cpu_speed} );    #truncate to 1 decimal place
            print "    CPUspeed=$pseries{$key}{lpars}{$lpar}{cpu_speed} Ghz" if ($verbose eq "yes");
            #
            #
            # Get the version and patch level of DB2 for each instance of DB2 on this this LPAR
            $pseries{$key}{lpars}{$lpar}{db2level} = `ssh $pseries{$key}{lpars}{$lpar}{name} "test -e /usr/local/bin/db2ls && /usr/local/bin/db2ls | grep -v ^Install | grep -v \- | tr -s ' ' | cut -d ' ' -f 1,2 | sed -e 's/^/\<br\>/' | sed -e 's/db2_software/ \- /g'" `;
            chomp $pseries{$key}{lpars}{$lpar}{db2level};				#remove newline
            $pseries{$key}{lpars}{$lpar}{db2level} = "not installed" unless ( $pseries{$key}{lpars}{$lpar}{db2level} =~ /[0-9]/ );	#put in a dummy value if DB2 is not installed
            print "    DB2level=$pseries{$key}{lpars}{$lpar}{db2level} " if ($verbose eq "yes");
            #
            # Get the Oracle instance name for each instance of Oracle on this this LPAR
            $pseries{$key}{lpars}{$lpar}{oracleinstance} = "";			#initialize variable
            $pseries{$key}{lpars}{$lpar}{oracleinstance} = `ssh $pseries{$key}{lpars}{$lpar}{name} "ps -ef | grep ora_smon_ | grep -v grep | sed -e \"s/.*ora_smon_//g\"  | grep [a-zA-Z0-9][a-zA-Z0-9]" `;
            chomp $pseries{$key}{lpars}{$lpar}{oracleinstance};				#remove newline
            $pseries{$key}{lpars}{$lpar}{oracleinstance} = "not installed" unless ( $pseries{$key}{lpars}{$lpar}{oracleinstance} =~ /[0-9a-zA-Z]/ );	#put in a dummy value if Oracle is not installed
            print "    oracleinstance=$pseries{$key}{lpars}{$lpar}{oracleinstance} " if ($verbose eq "yes");
            #
            #
            # Get the disk space used by the LPAR.  Note that we cannot get this from the HMC, so we ssh directly to the LPAR.
            # This assumes we have ssh keys setup to each LPAR and VIO
            if ($pseries{$key}{lpars}{$lpar}{os} eq "Linux") {
               $disktotal = 0;								#initialize variable
               # OUTSTANDING TASK: vgdisplay can only be run by the root user on Linux.  Figure out another way.
               #@vglist = `$ssh  $pseries{$key}{lpars}{$lpar}{name} vgdisplay -c | cut -d : -f 1`;
               #foreach my $vg (@vglist) {
               #   open (VG, "$ssh  $pseries{$key}{lpars}{$lpar}{name} vgdisplay -c $vg | cut -d : -f 12 |");
               #   while (<VG>) {
               #      if (/[0-9]+/) {							#find the total KB in each volume group 
               #         $disktotal = $disktotal + $1;					#keep running total of all disk in all volume groups
               #      }									#end of if block
               #   }									#end of while loop
               #   close VG;								#close filehandle
               #}									#end of foreach loop
               #$disktotal = $disktotal / 1024 / 1024;					#convert KB to GB
            } 										#end of if block
            if ($pseries{$key}{lpars}{$lpar}{os} eq "AIX") {
               $disktotal = 0;								#initialize variable
               @vglist = `$ssh  $pseries{$key}{lpars}{$lpar}{name} lsvg -o`;
               foreach my $vg (@vglist) {
                  open (VG, "$ssh  $pseries{$key}{lpars}{$lpar}{name} lsvg $vg |");
                  while (<VG>) {
                     if (/TOTAL PPs: +[0-9]+ \(([0-9]+) megabytes\)/) {			#find the total MB in each volume group (ignoring varied off volume groups)
                        $disktotal = $disktotal + $1;					#keep running total of all disk in all volume groups
                     }									#end of if block
                  }									#end of while loop
                  close VG;								#close filehandle
               }									#end of foreach loop
               $disktotal = $disktotal / 1024;						#convert MB to GB
            } 										#end of if block
            $disktotal = sprintf( "%.0f", $disktotal );					#truncate to 0 decimal places - within 1GB is close enough
            $disktotal = "unknown" if ( $disktotal == 0 );				#if the $disktotal is still zero, it probably means we could not ssh into the host.  Replace value with "unknown" in HTML report.
            $pseries{$key}{lpars}{$lpar}{disktotal} = $disktotal;			#assign value to hash
            print "    disktotal=$pseries{$key}{lpars}{$lpar}{disktotal} GB " if ($verbose eq "yes");
         }                                                      	                #end of if block
      }                                                                		      	#end of while loop
   }  											#end of foreach block
}            										#end of subroutine






sub print_html_header {
   #
   # generate HTML opening tags
   #
   print "running print_html_header subroutine \n" if ($verbose eq "yes");
   #
   print "<html><head><title>POWER Hardware Inventory Report</title><body> \n";
   print "<h3>POWER Hardware Inventory Report</h3> \n"; 
   print "<p>This report was automatically generated by the $0 script at $date \n";
   print "<p>&nbsp; \n";
}										#end of subroutine




sub print_inventory_info {
   #
   # generate inventory info
   #
   print "running print_inventory_info subroutine \n" if ($verbose eq "yes");
   #
   foreach $key (sort keys %pseries) {
      @lpars = ();								#clear the @lpars array (unique across each managed system) 
      next if ( $pseries{$key} eq "" );						#skip any blank array elements that may exist
      #
      #
      # print the HTML table that shows info for the managed system    
      print "<br><hr> \n";
      print "<table border=1> \n";
      print "<tr><td colspan=10 bgcolor=yellow> $pseries{$key}{name}                                             \n";
      print "<tr><td>Installed Memory                <td colspan=9>$pseries{$key}{installed_sys_mem} GB          \n";
      print "<tr><td>Configurable / Licensed  Memory <td colspan=9>$pseries{$key}{configurable_sys_mem} GB       \n";
      print "<tr><td>Memory used by hypervisor       <td colspan=9>$pseries{$key}{sys_firmware_mem} GB           \n";
      print "<tr><td>Memory used by LPARs            <td colspan=9>$pseries{$key}{used_sys_mem} GB               \n";
      print "<tr><td>Free Memory                     <td colspan=9>$pseries{$key}{curr_avail_sys_mem} GB         \n";
      print "<tr><td>Installed CPU                   <td colspan=9>$pseries{$key}{installed_sys_proc_units}      \n";
      print "<tr><td>Configurable CPU                <td colspan=9>$pseries{$key}{configurable_sys_proc_units}   \n";
      print "<tr><td>Used CPU                        <td colspan=9>$pseries{$key}{used_sys_proc_units}           \n";
      print "<tr><td>Free CPU                        <td colspan=9>$pseries{$key}{curr_avail_sys_proc_units}     \n";
      print "<tr><td colspan=10 bgcolor=grey>LPAR Details \n";
      print "<tr><td bgcolor=grey>Hostname <td bgcolor=grey>Power state<td bgcolor=grey>LPAR ID <td bgcolor=grey>Memory <td bgcolor=grey>CPU Entitlement<td bgcolor=grey>CPU Speed<td bgcolor=grey>OS Version <td bgcolor=grey>DB2 Instance /  Version <td bgcolor=grey>Oracle Instance <td bgcolor=grey>Assigned Disk \n";
      #
      #
      # Now show details for each LPAR
      # ssh into the HMC/IVM just to get the names of all the LPARs
      open (IN, "$ssh $pseries{$key}{ssh_userid}\@$pseries{$key}{ssh_mgmtconsole} \"lssyscfg -r lpar -m $pseries{$key}{name}\" |");
      while (<IN>) {
         #
         if (/name=([a-zA-Z0-9_\-]+),/) {                                 	#find name of LPAR
            push (@lpars,$1);  							#get all the lpar names into an array
         }									#end of if block
         @lpars = sort @lpars; 							#sort the lpars by name
      }										#end of while loop   
      foreach $lpar (@lpars) { 							#loop through for each LPAR on this managed system
         next if ( $pseries{$key}{lpars}{$lpar}{state} eq "Not Activated" ); #skip LPARs that are not running
         print "<tr><td> $pseries{$key}{lpars}{$lpar}{name} \n";
         print "    <td> $pseries{$key}{lpars}{$lpar}{state} \n";
         print "    <td> $pseries{$key}{lpars}{$lpar}{lpar_id} \n";
         print "    <td> $pseries{$key}{lpars}{$lpar}{memory} GB \n";
         print "    <td> $pseries{$key}{lpars}{$lpar}{curr_proc_units}\n";
         print "    <td> $pseries{$key}{lpars}{$lpar}{cpu_speed} Ghz\n";
         print "    <td> $pseries{$key}{lpars}{$lpar}{os_version}\n";
         print "    <td> $pseries{$key}{lpars}{$lpar}{db2level}\n";
         print "    <td> $pseries{$key}{lpars}{$lpar}{oracleinstance}\n";
         print "    <td> $pseries{$key}{lpars}{$lpar}{disktotal} GB\n";
      }										#end of foreach block
      close IN;									#close filehandle
      print "</table> \n\n";							#end of HTML table
   }										#end of foreach loop
}										#end of subroutine







sub print_html_footer {
   #
   # generate HTML closing tags
   #
   print "running print_html_footer subroutine \n" if ($verbose eq "yes");
   #
   print "\n\n\n</body></html> \n";
}										#end of subroutine








# ------------------ main body of program ----------------------------------
sanity_checks;
get_pseries_serial_numbers;
get_pseries_cpu;
get_pseries_memory;
get_lpar_details;
print_html_header;
print_inventory_info;
print_html_footer;



