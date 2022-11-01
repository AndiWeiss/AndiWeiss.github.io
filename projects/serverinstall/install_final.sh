#!/bin/bash

function install_package ()
{
	package="$1"
	echo -n "check if ${package} already installed ... "
	dpkg -l | grep " ${package} " > /dev/null
	if [ $? -ne 0 ];
	then
		echo "no"
		echo "install ${package} ..."
		apt-get install --assume-yes ${package}
		if [ $? -ne 0 ];
		then
			echo "installation of ${package} failed"
			exit 1
		fi
		echo "${package} installed."
		return 1
	else
		echo "yes"
		return 0
	fi
}

echo "get newest version of system"
apt-get update
if [ $? -ne 0 ];
then
	echo "apt-get update failed!"
	exit 1
fi

apt-get upgrade --assume-yes
if [ $? -ne 0 ];
then
	echo "apt-get upgrade failed!"
	exit 1
fi

install_package "geany"
install_package "gnome-system-tools"

echo -n "check if inputrc already patched ..."
grep '# \"\\e\[\([56]\)~\": history-search-' /etc/inputrc > /dev/null
if [ $? -eq 0 ];
then
	echo "no"
	echo "patching inputrc ..."
	cat /etc/inputrc | sed -n 's|# \"\\e\[\([56]\)~\": history-search-|\"\\e\[\1~\": history-search-|g;p' > /etc/inputrc.new
	mv /etc/inputrc /etc/inputrc.orig
	mv /etc/inputrc.new /etc/inputrc
else
	echo "yes"
fi

echo -n "check if openssh-server already installed ... "
install_package openssh-server
if [ $? -eq 1 ];
then
	echo "copy backup keys on server ..."
	cp -p /root/backup/initial/etc/ssh/*key* /etc/ssh
	echo "openssh-server including keys initiated."
fi

echo -n "checking if bluetooth is enabled ... "
if [ "`systemctl is-enabled bluetooth`" == "enabled" ];
then
	echo "yes"
	echo "disabling bluetooth"
	systemctl disable bluetooth
else
	echo "no"
fi

swappart="`swapon -s | grep "/dev/" | sed -n "s|^.*\(/[^/ ]*\).*$|\1|g;p"`"
swapuuid="`blkid --match-tag UUID --output value /dev${swappart}`"
do_grubupdate=0
echo "found swap partition /dev${swappart} with uuid ${swapuuid}"

echo -n "checking if kernel commandline contains hibernation ... "
file="/etc/default/grub"
grep "^[^#]*GRUB_CMDLINE_LINUX_DEFAULT=.*resume=UUID=" "${file}" > /dev/null
if [ $? -ne 0 ];
then
	echo "no"
	echo "patching ${file}"
	cat ${file} | sed -n "s|^\([^#]*GRUB_CMDLINE_LINUX_DEFAULT=\)\"\(.*\)\"\(.*\)$|\1\"\2 resume=UUID=${swapuuid}\"\3|g;p" > ${file}.new
	mv ${file} ${file}.orig
	mv ${file}.new ${file}
	do_grubupdate=1
else
	echo "yes"
fi

file=/etc/initramfs-tools/conf.d/resume
echo -n "checking if ${file} exists ... "
if [ -f "${file}" ];
then
	echo "yes"
	echo -n "checking if ${file} contains resume information ... "
	grep "RESUME=UUID=" ${file} > /dev/null
	if [ $? -eq 0 ];
	then
		echo "yes"
	else
		echo "no"
		echo "patching resume information into ${file}"
		echo >> ${file}
		echo "RESUME=UUID=${swapuuid}" >> ${file}
		do_grubupdate=1
	fi
else
	echo "no"
	echo "creating ${file}"
	echo "RESUME=UUID=${swapuuid}" > ${file}
	do_grubupdate=1
fi

if [ ${do_grubupdate} -ne 0 ];
then
	echo "grub update is required"
	update-grub
	if [ $? -ne 0 ];
	then
		echo "update-grub failed!"
		exit 1
	else
		echo "update-grub succeeded"
	fi
	update-initramfs -u -k all
	if [ $? -ne 0 ];
	then
		echo "update-initramfs failed!"
		exit 1
	else
		echo "update-initramfs succeeded"
	fi
fi

install_package "ethtool"
install_package "git"
install_package "dkms"

ethdev="`ip link | grep BROADCAST | sed -n 's|^[0-9]: *\([^:]*\):.*$|\1|g;p'`"
echo -n "checking if wake on lan is supported ... "
ethtool enp2s0 | grep Wake-on > /dev/null
if [ $? -ne 0 ];
then
	echo "no"
	echo -n "checking if alx-wol already available ... "
	if [ -d /root/backup/alx-wol ];
	then
		echo "yes"
	else
		echo "no"
		echo "fetching alx-wol"
		git clone https://github.com/AndiWeiss/alx-wol.git /root/backup/alx-wol
		if [ $? -ne 0 ];
		then
			echo "fetching alx-wol failed!"
			exit 1
		fi
	fi
	echo -n "checking if alx-wol already configured ... "
	dkms status | grep "alx-wol" > /dev/null
	if [ $? -ne 0 ];
	then
		echo "no"
		./alx-wol/install_alx-wol.sh --force
		if [ $? -ne 0 ];
		then
			echo "alx-wol installation failed!"
			exit 1
		fi
		echo "alx-wol installation succeeded"
	else
		echo "yes"
	fi
else
	echo "yes"
fi

echo -n "checking if wake on lan reacts on magical package only ... "
chk="`ethtool ${ethdev} | grep "^[[:blank:]]*Wake-on" | sed -n 's|^.*: ||g;p'`"
if [ "${chk}" != "g" ];
then
	echo "no"
	chk=/etc/systemd/system/wol.service
	echo -n "check if ${chk} exists ... "
	if [ -f "${chk}" ];
	then
		echo "yes"
	else
		echo "no"
		echo "create ${chk}"

		echo "[Unit]" > ${chk}
		echo "Description=Configure Wake-up on LAN" >> ${chk}
		echo >> ${chk}
		echo "[Service]" >> ${chk}
		echo "Type=oneshot" >> ${chk}
		echo "ExecStart=/sbin/ethtool -s ${ethdev} wol g" >> ${chk}
		echo >> ${chk}
		echo "[Install]" >> ${chk}
		echo "WantedBy=basic.target" >> ${chk}

		echo "enable service wol"
		systemctl enable wol.service
		if [ $? -ne 0 ];
		then
			echo "enabling service wol failed!"
			exit 1
		fi
		ethtool -s ${ethdev} wol g
	fi
else
	echo "yes"
fi

install_package "nfs-kernel-server"
install_package "net-tools"

echo -n "checking if autosuspend.sh already available ... "
if [ -f "/bin/autosuspend.sh" ];
then
	echo "yes"
else
	echo "no"
	wget https://AndiWeiss.github.io/projects/serverinstall/autosuspend.sh
	if [ $? -eq 0 ];
	then
		echo "fetching autosuspend.sh succeeded"
		chmod a+x autosuspend.sh
		mv autosuspend.sh /bin/autosuspend.sh
	else
		echo "fetching autosuspend.sh failed!"
		exit 1
	fi
fi

echo -n "checking if autosuspend already inserted in /etc/crontab ... "
grep "^[[:blank:]]*[^#]*/bin/autosuspend" /etc/crontab > /dev/null
if [ $? -ne 0 ];
then
	echo "no"
	echo >> /etc/crontab
	echo "* * * * * root /bin/autosuspend.sh" >> /etc/crontab
	echo "crontab extension succeded"
else
	echo "yes"
fi

