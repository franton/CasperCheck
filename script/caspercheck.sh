#!/bin/bash

# Massively reworked version of Rich Trouton's caspercheck script

# Variables go here
jss_server_address=$( defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url | awk -F':' '{print $1":"$2}' )
jss_server_port=$( defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url | cut -d":" -f3 | tr -d / )

logfolder="/private/var/log/company/"
log_location=$logfolder"jsscheck.log"

quickadd_dir="/usr/local/company/quickadd"
quickadd_installer="$quickadd_dir/QuickAdd.pkg"

error_flag=0

if [ ! -d "$logfolder" ];
then
	mkdir $logfolder
fi

# Logging function here
function logme()
{
# Check to see if function has been called correctly
	if [ -z "$1" ]
	then
		echo $( date )" - logme function call error: no text passed to function! Please recheck code!"
		echo $( date )" - logme function call error: no text passed to function! Please recheck code!" >> $LOG
		exit 1
	fi

# Log the passed details
	echo -e $( date )" - $1" >> $log_location
	echo -e $( date )" - $1"
}

echo "" >> $log_location
logme "Starting JSS Checking"

# Check for active network connection
logme "Checking for an active network connection"

if [ $( ifconfig -a inet 2>/dev/null | sed -n -e '/127.0.0.1/d' -e '/0.0.0.0/d' -e '/inet/p' | wc -l | awk '{ print $1 }' ) = "0" ];
then
	logme "Active network connection is not present. Exiting."
	exit 0
else
	logme "Active network connection present."
fi

# Pause for two minutes to allow network services to become fully active
logme "Waiting one minute to allow network services to initialise"
sleep 60

# We have network, do we have internet?
logme "Checking for active internet connection"

if [ $( curl -sq http://captive.apple.com | grep "Success" | wc -l | awk '{ print $1 }' ) = "0" ];
then
	logme "Active internet connection is not present. Exiting."
	exit 0
else
	logme "Active internet connection present."
fi

# Is the remote management server active?
logme "Checking if we can contact the management server"

if [ $( nc -z -w 5 $jss_server_address $jss_server_port > /dev/null; echo $? ) = "0" ];
then
	logme "Machine can connect to $jss_server_address over port $jss_server_port."
else
	logme "Machine cannot connect to $jss_server_address over port $jss_server_port. Exiting."
	exit 0
fi

# Does jamf binary exist on the system?
logme "Checking for the presence of the jamf binary"
jamf_binary=`/usr/bin/which jamf`

if [[ "$jamf_binary" == "" ]] && [[ -e "/usr/sbin/jamf" ]] && [[ ! -e "/usr/local/bin/jamf" ]];
then
	jamf_binary="/usr/sbin/jamf"
elif [[ "$jamf_binary" == "" ]] && [[ ! -e "/usr/sbin/jamf" ]] && [[ -e "/usr/local/bin/jamf" ]];
then
	jamf_binary="/usr/local/bin/jamf"
elif [[ "$jamf_binary" == "" ]] && [[ -e "/usr/sbin/jamf" ]] && [[ -e "/usr/local/bin/jamf" ]];
then
	jamf_binary="/usr/local/bin/jamf"
fi

if [ "$jamf_binary" = "" ];
then
	logme "Jamf binary not found."
	((error_flag++))
else
	logme "Jamf binary found at: $jamf_binary"
fi

# Verify jamf binary permissions
logme "Checking jamf binary permissions"
/usr/bin/chflags noschg $jamf_binary
/usr/bin/chflags nouchg $jamf_binary
/usr/sbin/chown root:wheel $jamf_binary
/bin/chmod 755 $jamf_binary

# Can jamf binary contact home server?
logme "Checking if jamf binary can contact management server"

if [ $( $jamf_binary checkJSSConnection > /dev/null; echo $? ) != "0" ];
then
	logme "Jamf binary connection to server failed."
	((error_flag++))
else
	logme "Jamf binary connection to server ok."
fi

# Can we run a test policy as a check?
logme "Running test policy"

if [ $( $jamf_binary policy -trigger isjssup | grep "Script result: up" | wc -l) != "1" ];
then
	logme "Test policy failed."
	((error_flag++))
else
	logme "Test policy succeeded."
fi

# If we failed any of these take remedial action
if [ "$error_flag" != "0" ];
then
	logme "Errors detected. Taking remedial action."
    /usr/sbin/installer -dumplog -verbose -pkg "$quickadd_installer" -target / 2>&1 | tee -a ${log_location}
	logme "Jamf agent reinstalled."
else
	logme "No errors detected. Exiting."
fi

# And we're done!