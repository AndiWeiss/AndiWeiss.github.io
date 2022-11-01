#!/bin/bash
# either no parameter then don't search for pool disks
# or parameter -init then search for pool disks

# dataset rpool/USERDATA is moved in any case
# the following datasets are located in
# rpool/ROOT/ubuntu_${MyId}/

zfs_patchname="zsys-setup_22.04.patch"
datasets_to_move="srv var/log var/www"
expected_hdds_for_tank0="1 4"

init_pool=0
if [ $# -eq 1 ];
then
	if [ "$1" == "--init" ];
	then
		init_pool=1
	fi
fi

function inst_abort ()
{
	until [ -z "$1" ];
	do
		echo "$1" 1>&2
		shift
	done
	echo "installation aborted" 1>&2

	zpool list tank0 >& /dev/null
	if [ $? -eq 0 ];
	then
		zpool export tank0
	fi

	zpool list bpool >& /dev/null
	if [ $? -eq 0 ];
	then
		zpool export bpool
	fi

	zpool list rpool >& /dev/null
	if [ $? -eq 0 ];
	then
		zpool export rpool
	fi

	exit 1
}

function readdisks ()
{
	tmp="`find /dev/disk/by-id/ -type l | grep -v 'wwn-'`"
	tmp=`realpath ${tmp} | grep '.*[^0-9]$'`
	tmp=`echo "${tmp}" | sort`
	echo "${tmp}"
}

function read_pools ()
{
	echo "`zpool import | grep '^[[:blank:]]*pool:' | sed -n 's|^[[:blank:]]*pool:[[:blank:]]*||g;p' | sort`"
}

function get_model ()
{
	hwinfo --disk --only $1 --short | grep /dev | sed -n "s|^.*$1[[:space:]]*||g;p"
}

function create_ds ()
{
	if [ $# -eq 1 ];
	then
		echo "create dataset $1"
		zfs create "$1"
	elif [ $# -eq 2 ];
	then
		echo "create dataset $1 with mountpoint $2"
		zfs create -o mountpoint="$2" "$1"
	else
		inst_abort "create_ds: wront parameter count"
	fi

	if [ $? -ne 0 ];
	then
		inst_abort "creation of $1 failed"
	fi
}

if [ "`whoami`" != "root" ];
then
	inst_abort "this script has to be executed as root"
fi

which hwinfo
if [ $? -ne 0 ];
then
	echo "have to install hwinfo ..."
	apt-get install --assume-yes hwinfo
fi

chkdisks="`readdisks`"

livelinux="${chkdisks}"
echo "livelinux is on ${livelinux}"

echo "plugin drive which shall be used for installation"
while true;
do
	chkdisks="`readdisks`"
	if [ "${chkdisks}" != "${livelinux}" ];
	then
		break
	fi
	sleep 1
done

for disk in ${chkdisks};
do
	echo "${livelinux}" | grep -l "${disk}" > /dev/null
	if [ $? -ne 0 ];
	then
		installdisk=${disk};
		break
	fi
done
echo "found plugged disk >${installdisk}<"

model=`get_model ${installdisk}`
echo "shall the drive"
echo "${installdisk} - \"${model}\""
echo "be used for installation?"
echo "KEEP CARE, IT WILL BE COMPLETELY OVERWRITTEN!"
echo "type \"yes\""
read -r line

if [ "${line}" != "yes" ];
then
	inst_abort
fi

echo "OK, first remove any filsystem fragment on this disk ..."

for part in `ls ${installdisk}*`;
do
	if [ "${part}" != "${installdisk}" ];
	then
		wipefs -a "${part}"
	fi
done
echo wipefs -a "${installdisk}"

if [ ! -f "${zfs_patchname}" ];
then
	echo "now patching the zfs installer ..."
	orig="`pwd`"
	wget https://andiweiss.github.io/projects/serverinstall/${zfs_patchname}
	cd /usr/share/ubiquity
	patch -p1 < "${orig}/${zfs_patchname}"
	if [ $? -ne 0 ];
	then
		inst_abort "zfs installer patch failed"
	fi
	cd ${orig}
	echo "zfs installer patch succeeded"
fi

echo "disk ${installdisk} is ready for installation now."
echo "start the installation using this disk"
echo "press enter after installation is finished"
read -r line

echo "you explained that installation finished ..."
echo "short pause ..."
sleep 2

if [ $init_pool -eq 1 ];
then
	echo "now plugin all disks you want to use for your data tank."
	echo "type f when all disks are connected"

	all_disks="${chkdisks}"
	all_tankdrives=

	while true;
	do
		chkdisks="`readdisks`"
		if [ "${chkdisks}" != "${all_disks}" ];
		then
			for cur in ${chkdisks};
			do
				echo "${all_disks}" | grep "${cur}" > /dev/null
				if [ $? -ne 0 ];
				then
					if [ -z "${all_tankdrives}" ];
					then
						all_tankdrives="${cur}"
					else
						all_tankdrives="${all_tankdrives} ${cur}"
					fi
					echo -e "${cur}\t`get_model ${cur}`"
				fi
			done
			all_disks=${chkdisks}
		fi
		read -t 0.25 -N 1 line
		if [ "${line}" == "f" ];
		then
			echo
			break
		fi
	done

	for dev in ${all_tankdrives};
	do
		find ${dev}[0-9] -type f >& /dev/null
		if [ $? -eq 0 ];
		then
			inst_abort "there are partitions on ${dev}!"
		fi
	done

	zpool import -R /target rpool
	if [ $? -ne 0 ];
	then
		inst_abort "import of rpool failed"
	fi

	zpool import -R /target bpool
	if [ $? -ne 0 ];
	then
		zpool export rpool
		inst_abort "import of bpool failed"
	fi

	echo "CAUTION!"
	echo "drive initialization deletes all data on the drives!"
	echo "shall these drives really initialized (yes)?"
	line=
	read -r line
	if [ "${line}" != "yes" ];
	then
		inst_abort "drives shall not be initialized."
	fi

	# initialize drives here
	n=`echo "${all_tankdrives}" | wc -w`
	match=0
	for m in ${expected_hdds_for_tank0};
	do
		if [ $n -eq $m ];
		then
			match=1
			break
		fi
	done

	if [ $match -ne 1 ];
	then
		inst_abort "this script can only handle" \
			"${expected_hdds_for_tank0}" \
			"hdds for tank0." \
			"instead found $n"
	fi

	echo "creating pool \"tank0\" ..."

	if [ $n -eq 4 ];
	then
		type="raidz"
	elif [ $n -eq 2 ];
	then
		type="mirror"
	else
		type=""
	fi

	wwns=
	for disk in ${all_tankdrives};
	do
		wwn="`basename ${disk}`"
		wwn="`ls -l /dev/disk/by-id/ | grep "wwn-.*${wwn}$"`"
		wwn="`echo "${wwn}" | sed -n "s|^.*\(wwn-[^ ]*\).*$|/dev/disk/by-id/\1|g;p"`"
		if [ -z "${wwns}" ];
		then
			wwns="${wwn}"
		else
			wwns="${wwns} ${wwn}"
		fi
	done

	echo "create pool tank0 (${type} ${wwns})"
	zpool create -f \
		-o ashift=12 \
		-o autotrim=on \
		-O compression=lz4 \
		-O acltype=posixacl \
		-O xattr=sa \
		-O relatime=on \
		-O normalization=formD \
		-O mountpoint=none \
		-O canmount=off \
		-O dnodesize=auto \
		-O sync=disabled \
		-R /tank0 \
		tank0 ${type} \
			${wwns}
	if [ $? -ne 0 ];
	then
		inst_abort "pool tank0 creation failed"
	fi

	ds="root"
	create_ds tank0/${ds} /${ds}
	chown --reference=/target/${ds} /tank0/${ds}
	chmod --reference=/target/${ds} /tank0/${ds}
	orig="`pwd`"
	cd "/target/${ds}"
	for d in `find . -mindepth 1 -maxdepth 1`;
	do
		cp -pr "${d}" "/tank0/${ds}"
	done
	cd "${orig}"

	ds="home"
	create_ds tank0/${ds} /${ds}
	chown --reference=/target/${ds} /tank0/${ds}
	chmod --reference=/target/${ds} /tank0/${ds}

	ds="home/administrator"
	create_ds tank0/${ds}
	chown --reference=/target/${ds} /tank0/${ds}
	chmod --reference=/target/${ds} /tank0/${ds}
	orig="`pwd`"
	cd "/target/${ds}"
	for d in `find . -mindepth 1 -maxdepth 1`;
	do
		cp -pr "${d}" "/tank0/${ds}"
	done
	cd "${orig}"

	for ds in ${datasets_to_move};
	do
		echo "${ds}" | grep "/" > /dev/null
		if [ $? -eq 0 ];
		then
			dir=tank0
			list=`dirname "${ds}" | tr '/' ' '`
			for part in ${list}
			do
				dir="${dir}/${part}"
				zfs list ${dir} >& /dev/null
				if [ $? -ne 0 ];
				then
					zfs create -o canmount=off -o mountpoint=none ${dir}
					if [ $? -ne 0 ];
					then
						inst_abort "creation of ${dir} failed"
					fi
				fi
			done
		fi
		create_ds "tank0/${ds}" "/${ds}"
		chown --reference=/target/${ds} /tank0/${ds}
		chmod --reference=/target/${ds} /tank0/${ds}
		orig="`pwd`"
		cd "/target/${ds}"
		for d in `find . -mindepth 1 -maxdepth 1`;
		do
			cp -pr "${d}" "/tank0/${ds}"
		done
		cd "${orig}"
	done

	echo "copy initial data to tank0 finished"
else
	echo "tank0 shall not be initialized"

	zpool import -R /target rpool
	if [ $? -ne 0 ];
	then
		inst_abort "import of rpool failed"
	fi
fi

echo "destroying defined data sets on the installation drive ..."

zfs destroy -r "rpool/USERDATA"
if [ $? -ne 0 ];
then
	inst_abort "destruction of rpool/USERDATA failed"
fi

MyId=`zfs list | grep ROOT/ubuntu_.*/target\$ | sed -n 's|[^_]*_\(\w*\).*|\1|g;p'`

for ds in ${datasets_to_move};
do
	zfs destroy -r "rpool/ROOT/ubuntu_${MyId}/${ds}"
	if [ $? -ne 0 ];
	then
		inst_abort "destruction of rpool/ROOT/ubuntu_${MyId}/${ds} failed"
	fi
done

echo "destruction of defined datasets succeeded"

echo "exporting zpools"

poolexport_failed=0

if [ $init_pool -eq 1 ];
then
	zpool export tank0
	if [ $? -ne 0 ];
	then
		echo "export of tank0 failed" 1>&2
		poolexport_failed=1
	fi
fi

zpool export bpool
if [ $? -ne 0 ];
then
	echo "export of bpool failed" 1>&2
	poolexport_failed=1
fi

zpool export rpool
if [ $? -ne 0 ];
then
	echo "export of rpool failed" 1>&2
	poolexport_failed=1
fi

if [ $poolexport_failed -ne 0 ];
then
	echo "at least one pool export failed." 1>&2
	echo "check output and do a manual export" 1>&2
	echo "after that boot the installed system" 1>&2
	echo "and import tank0" 1>&2
	exit 1
fi

echo "system installation succeeded"
echo "now do boot the installed system"
echo "and import tank0"
