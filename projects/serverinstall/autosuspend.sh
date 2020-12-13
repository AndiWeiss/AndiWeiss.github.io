#!/bin/bash

timeout=15
tmpfile="/tmp/autosuspend"

# read timer file
if [ -e ${tmpfile} ];
then
	readval=$(cat ${tmpfile})
	case $readval in
		# check for digits
		# use 0 if there is something else
		''|*[!0-9]*) count=0 ;;

		# use a valid value
		*) count=$readval ;;
	esac
else
	# if the file doesn't exist start with 0
	count=0
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
		break
	fi
done

# if no alive set up to here
if [ "$keepalive" = "0" ];
then
	# check if users are logged in
	users=$(/usr/bin/users)

	# if yes:
	if [ "$users" != "" ];
	then
		# keep alive
		keepalive=1
	fi
fi

# if nothing leads to keepalive
if [ "$keepalive" -eq "0" ];
then
	# increment counter
	count=$(( $count + 1 ))

	# if below timeout
	if [ "$count" -le "$timeout" ];
	then
		# store the new value
		echo "$count" > "$tmpfile"
	else
		# if timeout ocured:
		# use '0' as starting value
		echo "0" > "$tmpfile"

		# then suspend
		sudo /usr/sbin/s2both
	fi
fi
