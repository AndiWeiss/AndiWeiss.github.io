#!/bin/bash

# Functionality of this script:
# 1. check if the script actually is doing updates
#    if yes: simply exit
# 2. read time value out of tempfile
#    if no tempfile available: start with time 0
# 3. get ips of active nfs shares
# 4. for each of the shares:
#    check if the user is still active (ping the system)
#    if yes: mark as 'don't shut down'
# 5. if no active share detected:
#    check if a user is logged in
#    if yes: mark as 'don't shut down'
# 6. if running system required:
#        store 0 as counter value
#    else
#    6a: increment counter
#        store counter value
#    6b: if counter for update reached:
#        - create file to mark 'updates in progress'
#        - do the updates
#        - delete file to remove 'update in progress' marker
#        - check if reboot required
#          if yes: do the reboot
#    6c: if counter for shutdown is reached:
#        - store counter value 0
#        - shut down

# configuration:
# timeout_update: this amount of calls after inactivity check for updates
# timeout:        this amount of calls after inactivity shut down the system
#                 timeout has to be larger than timeout_update!
# tmpfile:        store the amount of calls
#                 ${tmpfile}.update is used to lock for updates!
# loglevel:       0 --> no log
#                 1 --> log reboots (NOT regular shutdowns!)
#                 2 --> additionally log wakeup and sleep events
#                 3 --> log everything
# logfile:        File where log is written to

timeout_update=10
timeout=$(( $timeout_update + 5 ))
tmpfile="/tmp/autosuspend"
loglevel=2
logfile="/var/log/autosuspend.log"

logstring ()
{
	if [ "$1" -le "$loglevel" ];
	then
		if [ "$logfile" != "" ];
		then
			echo "$(date +"%Y-%m-%d %H:%M:%S") - $2" >> "$logfile"
		fi
	fi
}

if [ -e "${tmpfile}.update" ];
then
	logstring 3 "updates active, exit"
	exit
fi

# read timer file
if [ -e "${tmpfile}" ];
then
	readval=$(cat "${tmpfile}")
	case $readval in
		# check for digits
		# use 0 if there is something else
		''|*[!0-9]*) count=0 ;;

		# use a valid value
		*) count=$readval ;;
	esac
	logstring 3 "timer file read, contains $readval --> $count"
else
	# if the file doesn't exist
	# we assume the system has been woken up
	count=0
	logstring 2 "wakeup"
	echo "$count" > "$tmpfile"
fi

# get lines of NFS mounts
nfsmounters_ips=`netstat -n --inet | grep ':2049\W' | sed -n 's|.*:2049\W*\([^:]*\):.*|\1|g;p'`

# initialize with 'switch off'
keepalive=0

# for each nfs ip
for nfsmounter in ${nfsmounters_ips};
do
	# try to ping
	ping -c 5 -i 0,2 -q -n ${nfsmounter} > /dev/null
	result=$?

	# if the user system is alive
	if [ "$result" -eq "0" ];
	then
		# keep the server alive
		keepalive=1
		logstring 3 "nfs $nfsmounter still active"
	else
		logstring 3 "nfs $nfsmounter inactive"
	fi
done

# check if users are logged in
users=$(/usr/bin/users)

# if yes:
if [ "$users" != "" ];
then
	# keep alive
	keepalive=1
	logstring 3 "still detected users"
else
	logstring 3 "no users detected"
fi

# if nothing leads to keepalive
if [ "$keepalive" -ne "0" ];
then
	if [ "$count" -ne "0" ];
	then
		echo "0" > "${tmpfile}"
		logstring 3 "write 0 to timer file"
	fi
else
	# increment counter
	count=$(( $count + 1 ))

	# if updates timeout reached
	if [ "$count" -eq "$timeout_update" ];
	then
		logstring 3 "installing updates"
		touch "${tmpfile}.update"
		update_success=0
		if apt-get update;
		then
			logstring 3 "apt-get updates --> OK"
			if apt-get -yt $(lsb_release -cs)-security dist-upgrade;
			then
				logstring 3 "apt-get -yt $(lsb_release -cs)-security dist-upgrade --> OK"
				if apt-get --trivial-only dist-upgrade;
				then
					logstring 3 "apt-get --trivial-only dist-upgrade --> OK"
					if apt-get autoclean;
					then
						logstring 3 "apt-get autoclean --> OK"
						update_success=1
					else
						logstring 1 "apt-get autoclean --> FAILED"
					fi
				else
					logstring 1 "apt-get --trivial-only dist-upgrade --> FAILED"
				fi
			else
				logstring 1 "apt-get -yt $(lsb_release -cs)-security dist-upgrade --> FAILED"
			fi
		else
			logstring 1 "apt-get updates --> FAILED"
		fi
		rm -f "${tmpfile}.update"
		if [ "$update_success" -eq "1" ];
		then
			if [ -e "/var/run/reboot-required" ];
			then
				logstring 1 "reboot required, executing reboot!"
				reboot
			fi
		fi
	fi

	# if timeout reached
	if [ "$count" -gt "$timeout" ];
	then
		# if timeout ocured:
		# remove time file
		rm -f "$tmpfile"

		logstring 2 "shutting down ..."

		# set rtc alarm
		rtcwake -m no -t `date --date='7 days 04:00' +%s`

		# then suspend
		/usr/sbin/s2both
	else
		# store new value
		echo "$count" > "$tmpfile"
	fi
fi
