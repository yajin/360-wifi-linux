#!/bin/bash

function usage() {
    echo "[x] Usage: `basename $0` [360-wifi-interface] [public-network-interface] [password(optional)] "
    echo "   [360-wifi-interface]: the network interface of 360-wifi, wlan0 for example."
    echo "   [public-network-interface]: the network interface of public network, eth0 for example."
    echo "   [password(optional)]: password of your new WIFI network (>=8 bytes). "
    exit
}


if [ $# -lt 2 ] || [ $# -gt 3 ] ; then
    usage
fi

key=$(echo $RANDOM)$(echo $RANDOM)

if [ $# -eq 3 ]; then
    key=$3
fi

if [ ${#key} -lt 8 ]; then
    echo "[x] The length of password can not be less than 8."
    exit
fi


in_interface=$1
out_interface=$2

WIFI_HOME=~/.360wifi


#[1] Check whether we have 360 wifi inserted

echo "[*] Checking 360-wifi ... "
result=$(lsusb | grep -e "148f:5370 Ralink Technology")

if [ $? -ne 0 ]; then
    echo "[x] Please insert 360-wifi into the USB interface"
    exit
fi

#[2] check whether kernel has CONFIG_RT2800USB_RT53XX configuration
#CONFIG_RT2800USB_RT53XX=y
echo "[*] Checking kernel version ... "

kernel_version=$(uname -r)
# echo $kernel_version

result=$(cat /boot/config-$kernel_version | grep -e "CONFIG_RT2800USB_RT53XX=y")

if [ $? -ne 0 ]; then
    echo "[x] Sorry, your kernel version is not currently supported"
    exit
fi


# [3] install necessary packages
echo "[*] Installing necessary packages ... "
echo "    -->[a] hostapd"
sudo apt-get install hostapd > /dev/null

echo "    -->[b] isc-dhcp-server"
sudo apt-get install isc-dhcp-server > /dev/null


# [4] set isc-dhcp-server
echo "[*] Setting isc-dhcp-server ... "
if [ -f /etc/dhcp/dhcpd.$in_interface.conf ]; then
    sudo rm /etc/dhcp/dhcpd.$in_interface.conf
fi

ip_prefix=`ifconfig ${out_interface} | grep "inet addr" | awk -F: '{print $2}' | awk -F. '{print $1}'`
case ${ip_prefix} in
    "10")
        ip_prefix="172.16"
        ;;
    "172")
        ip_prefix="192.168"
        ;;
    "192")
        ip_prefix="10.0"
        ;;
    "")
        echo '!are you sure you have connected to internet'
        ;;
    *)
        echo '!!!some miracle'
        ;;
esac
subnet="${ip_prefix}.9"
echo "default-lease-time 600;
max-lease-time 7200;
log-facility local7;
subnet ${subnet}.0 netmask 255.255.255.0 {
    range ${subnet}.100 ${subnet}.200;
    option domain-name-servers 8.8.8.8;
    option routers ${subnet}.1;
    default-lease-time 600;
    max-lease-time 7200;
}" | sudo tee  /etc/dhcp/dhcpd.$in_interface.conf > /dev/null
sudo ifconfig $in_interface ${subnet}.1 up
sudo dhcpd -q -cf /etc/dhcp/dhcpd.$in_interface.conf -pf /var/run/dhcp-server/dhcpd.pid  $in_interface


echo "[*] Setting iptable ... "
forward=$(cat  /proc/sys/net/ipv4/ip_forward)
if [ $forward -eq "0" ]; then
    echo "    -->[*] Enabling ipv4 forwarding"
    echo 1  | sudo tee  /proc/sys/net/ipv4/ip_forward
fi
echo "    -->[*] Setting iptables rules"
sudo iptables -F
sudo iptables -t nat -F
sudo iptables -t nat -A POSTROUTING -s ${subnet}.0/24 -o $out_interface -j MASQUERADE
sudo iptables -A FORWARD -s ${subnet}.0/24 -o $out_interface -j ACCEPT
sudo iptables -A FORWARD -d ${subnet}.0/24 -m conntrack --ctstate ESTABLISHED,RELATED -i $out_interface -j ACCEPT

echo "[*] Setting hostapd ... "

ssid=360_FREE_WIFI$RANDOM

echo
echo "****  SSID : $ssid, key: $key. Enjoy! ****"
echo
function clean_up {
    echo "[*] Cleaning up ..."
    if [ -f /var/run/dhcp-server/dhcpd.pid ]; then
        dhcpd_pid=$(cat /var/run/dhcp-server/dhcpd.pid)
        sudo kill -9 $dhcpd_pid > /dev/null
        # echo $dhcpd_pid
    fi
}

trap 'clean_up;echo "Goodbye"' SIGINT SIGTERM SIGQUIT SIGKILL

if [ ! -d $WIFI_HOME ]; then
    mkdir $WIFI_HOME
fi

if [ -f $WIFI_HOME/.hostapd.$in_interface.conf ]; then
    rm $WIFI_HOME/.hostapd.$in_interface.conf
fi

echo "interface=$in_interface
driver=nl80211
ssid=$ssid
hw_mode=g
channel=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=3
wpa_passphrase=$key
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP" | tee  $WIFI_HOME/.hostapd.$in_interface.conf > /dev/null

# sudo hostapd $WIFI_HOME/.hostapd.$in_interface.conf  -P $WIFI_HOME/.hostapd.$in_interface.pid -B
sudo hostapd $WIFI_HOME/.hostapd.$in_interface.conf  > /dev/null
