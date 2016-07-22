#!/bin/bash

jss_server_address=$( defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url | awk -F':' '{print $1":"$2}' )

jss_server_port=$( defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url | cut -d":" -f3 | tr -d / )

#
# User-editable variables
#

# For the log_location variable, put the preferred 
# location of the log file for this script. If you 
# don't have a preference, using the default setting
# should be fine.

log_location="/var/log/organisationname/caspercheck.log"

#
# The variables below this line should not need to be edited.
# Use caution if doing so. 
#

quickadd_dir="/usr/local/org/misc/quickadd"
quickadd_installer="$quickadd_dir/casper.pkg"

#
# Begin function section
# =======================
#

# Function to provide custom curl options
myCurl () { /usr/bin/curl -k --retry 3 --silent --show-error "$@"; }

# Function to provide logging of the script's actions to
# the log file defined by the log_location variable

ScriptLogging(){

    DATE=`date +%Y-%m-%d\ %H:%M:%S`
    LOG="$log_location"
    
    echo "$DATE" " $1" >> $LOG
}

CheckForNetwork(){

# Determine if the network is up by looking for any non-loopback network interfaces.

    local test
    
    if [[ -z "${NETWORKUP:=}" ]]; then
        test=$(ifconfig -a inet 2>/dev/null | sed -n -e '/127.0.0.1/d' -e '/0.0.0.0/d' -e '/inet/p' | wc -l)
        if [[ "${test}" -gt 0 ]]; then
            NETWORKUP="-YES-"
        else
            NETWORKUP="-NO-"
        fi
    fi
}

CheckTomcat (){
 
# Verifies that the JSS's Tomcat service is responding via its assigned port.

tomcat_chk=`nc -z -w 5 $jss_server_address $jss_server_port 2&>1 > /dev/null; echo $?`

if [ "$tomcat_chk" -eq 0 ]; then
       ScriptLogging "Machine can connect to $jss_server_address over port $jss_server_port. Proceeding."
else
       ScriptLogging "Machine cannot connect to $jss_server_address over port $jss_server_port. Exiting CasperCheck."
       ScriptLogging "======== CasperCheck Finished ========"
       exit 0
fi

}

CheckBinary (){
 
# Identify location of jamf binary.
#
# If the jamf binary is not found, this check will return a
# null value. This null value is used by the CheckCasper
# function, in the "Checking for the jamf binary" section
# of the function.

jamf_binary=`/usr/bin/which jamf`

 if [[ "$jamf_binary" == "" ]] && [[ -e "/usr/sbin/jamf" ]] && [[ ! -e "/usr/local/bin/jamf" ]]; then
    jamf_binary="/usr/sbin/jamf"
 elif [[ "$jamf_binary" == "" ]] && [[ ! -e "/usr/sbin/jamf" ]] && [[ -e "/usr/local/bin/jamf" ]]; then
    jamf_binary="/usr/local/bin/jamf"
 elif [[ "$jamf_binary" == "" ]] && [[ -e "/usr/sbin/jamf" ]] && [[ -e "/usr/local/bin/jamf" ]]; then
    jamf_binary="/usr/local/bin/jamf"
 fi

}

InstallCasper () {
 
    ScriptLogging "Installing Casper quickadd package."
    /usr/sbin/installer -dumplog -verbose -pkg "$quickadd_installer" -target /
    ScriptLogging "Casper agent has been installed." 

}

CheckCasper () {

  #  CheckCasper function adapted from Facebook's jamf_verify.sh script.
  #  jamf_verify script available on Facebook's IT-CPE Github repo:
  #  Link: https://github.com/facebook/IT-CPE

  # Checking for the jamf binary
  CheckBinary
  if [[ "$jamf_binary" == "" ]]; then
    ScriptLogging "Casper's jamf binary is missing. It needs to be reinstalled."
    InstallCasper
    CheckBinary
  fi

  # Verifying Permissions
  /usr/bin/chflags noschg $jamf_binary
  /usr/bin/chflags nouchg $jamf_binary
  /usr/sbin/chown root:wheel $jamf_binary
  /bin/chmod 755 $jamf_binary
  
  # Verifies that the JSS is responding to a communication query 
  # by the Casper agent. If the communication check returns a result
  # of anything greater than zero, the communication check has failed.
  # If the communication check fails, reinstall the Casper agent using
  # the cached installer.

  jss_comm_chk=`$jamf_binary checkJSSConnection > /dev/null; echo $?`

  if [[ "$jss_comm_chk" -eq 0 ]]; then
       ScriptLogging "Machine can connect to the JSS on $jss_server_address."
  elif [[ "$jss_comm_chk" -gt 0 ]]; then
       ScriptLogging "Machine cannot connect to the JSS on $jss_server_address."
       ScriptLogging "Reinstalling Casper agent to fix problem of Casper not being able to communicate with the JSS."
       InstallCasper
       CheckBinary
  fi

  # Checking if machine can run a manual trigger
  # This section will need to be edited if the policy
  # being triggered has different options than the policy
  # described below:
  #
  # Trigger: iscasperup
  # Plan: Run Script iscasperonline.sh
  # 
  # The iscasperonline.sh script contains the following:
  #
  # | #!/bin/sh
  # |
  # | echo "up"
  # |
  # | exit 0
  #

  
  jamf_policy_chk=`$jamf_binary policy -trigger iscasperup | grep "Script result: up"`

  # If the machine can run the specified policy, exit the script.

  if [[ -n "$jamf_policy_chk" ]]; then
    ScriptLogging "Casper enabled and able to run policies"

  # If the machine cannot run the specified policy, 
  # reinstall the Casper agent using the cached installer.

  elif [[ ! -n "$jamf_policy_chk" ]]; then
    ScriptLogging "Reinstalling Casper agent to fix problem of Casper not being able to run policies"
    InstallCasper
    CheckBinary
  fi

}

#
# End function section
# ====================
#

# The functions and variables defined above are used
# by the section below to check if the network connection
# is live, if the machine is on a network where
# the Casper JSS is accessible, and if the Casper agent on the
# machine can contact the JSS and run a policy.
#
# If the Casper agent on the machine cannot run a policy, the appropriate
# functions run and repair the Casper agent on the machine.
#

ScriptLogging "======== Starting CasperCheck ========"

# Wait up to 60 minutes for a network connection to become 
# available which doesn't use a loopback address. This 
# condition which may occur if this script is run by a 
# LaunchDaemon at boot time.
#
# The network connection check will occur every 5 seconds
# until the 60 minute limit is reached.


ScriptLogging "Checking for active network connection."
CheckForNetwork
i=1
while [[ "${NETWORKUP}" != "-YES-" ]] && [[ $i -ne 720 ]]
do
    sleep 5
    NETWORKUP=
    CheckForNetwork
    echo $i
    i=$(( $i + 1 ))
done

# If no network connection is found within 60 minutes,
# the script will exit.

if [[ "${NETWORKUP}" != "-YES-" ]]; then
   ScriptLogging "Network connection appears to be offline. Exiting CasperCheck."
fi
   

if [[ "${NETWORKUP}" == "-YES-" ]]; then
   ScriptLogging "Network connection appears to be live."
  
  # Sleeping for 120 seconds to give WiFi time to come online.
  ScriptLogging "Pausing for two minutes to give WiFi and DNS time to come online."
  sleep 120

  CheckTomcat
  CheckCasper

fi

ScriptLogging "======== CasperCheck Finished ========"

exit 0
