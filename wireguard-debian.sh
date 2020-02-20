#!/bin/bash
echo "deb http://deb.debian.org/debian/ unstable main" > /etc/apt/sources.list.d/unstable.list
printf 'Package: *\nPin: release a=unstable\nPin-Priority: 90\n' > /etc/apt/preferences.d/limit-unstable
apt -y update
apt -y install wireguard curl ufw qrencode
mkdir -p /etc/wireguard
cd /etc/wireguard
SUBNET4="10.0.0."
SUBNET6="fd00::"
SRVADDR4="10.0.0.1/24"
SRVADDR6="fd00::1/64"
LISTENPORT="51820"
DNSSERVER="1.1.1.1, 2606:4700:4700::1111"
ETHERINT="eth0"
WGINT="wg0"
cat <<EOF > vpn_subnet4.var
$SUBNET4
EOF
cat <<EOF > vpn_subnet6.var
$SUBNET6
EOF
cat <<EOF > dns.var
$DNSSERVER
EOF
cat <<EOF > last_used_ip.var
1
EOF
cat <<EOF > endpoint.var
$(curl https://ipinfo.io/ip):$LISTENPORT
EOF
wg genkey | tee server_private_key | wg pubkey > server_public_key
cat <<EOF > wg0.conf
[Interface]
Address = $SRVADDR4, $SRVADDR6
ListenPort = $LISTENPORT
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $ETHERINT -j MASQUERADE; ip6tables -A FORWARD -i wg0 -j ACCEPT; ip6tables -A FORWARD -o wg0 -j ACCEPT; ip6tables -t nat -A POSTROUTING -o $ETHERINT -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $ETHERINT -j MASQUERADE; ip6tables -D FORWARD -i wg0 -j ACCEPT; ip6tables -D FORWARD -o wg0 -j ACCEPT; ip6tables -t nat -D POSTROUTING -o $ETHERINT -j MASQUERADE
PrivateKey = $( cat server_private_key )
EOF
cat <<'EOF' > add-client
#!/bin/bash

# We read from the input parameter the name of the client
if [ -z "$1" ]
  then 
    read -p "Enter VPN user name: " USERNAME
    if [ -z $USERNAME ]
      then
      echo "[#]Empty VPN user name. Exit"
      exit 1;
    fi
  else USERNAME=$1
fi

cd /etc/wireguard/

read DNS < ./dns.var
#read ENDPOINT < ./endpoint.var
ENDPOINT="$(curl https://ipinfo.io/ip):51820"
read VPN_SUBNET4 < ./vpn_subnet4.var
read VPN_SUBNET6 < ./vpn_subnet6.var
PRESHARED_KEY="_preshared.key"
PRIV_KEY="_private.key"
PUB_KEY="_public.key"
ALLOWED_IP="0.0.0.0/0, ::/0"

# Go to the wireguard directory and create a directory structure in which we will store client configuration files
mkdir -p ./clients
cd ./clients
mkdir ./$USERNAME
cd ./$USERNAME
umask 077

CLIENT_PRESHARED_KEY=$( wg genpsk )
CLIENT_PRIVKEY=$( wg genkey )
CLIENT_PUBLIC_KEY=$( echo $CLIENT_PRIVKEY | wg pubkey )

#echo $CLIENT_PRESHARED_KEY > ./"$USERNAME$PRESHARED_KEY"
#echo $CLIENT_PRIVKEY > ./"$USERNAME$PRIV_KEY"
#echo $CLIENT_PUBLIC_KEY > ./"$USERNAME$PUB_KEY"

read SERVER_PUBLIC_KEY < /etc/wireguard/server_public_key

# We get the following client IP address
read OCTET_IP < /etc/wireguard/last_used_ip.var
OCTET_IP=$(($OCTET_IP+1))
echo $OCTET_IP > /etc/wireguard/last_used_ip.var

CLIENT_IP4="$VPN_SUBNET4$OCTET_IP/32"
CLIENT_IP6="$VPN_SUBNET6$OCTET_IP/128"

# Create a blank configuration file client 
cat > /etc/wireguard/clients/$USERNAME/$USERNAME.conf << \EOF
[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = $CLIENT_IP4, $CLIENT_IP6
DNS = $DNS

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
PresharedKey = $CLIENT_PRESHARED_KEY
AllowedIPs = $ALLOWED_IP
Endpoint = $ENDPOINT
PersistentKeepalive=25
\EOF

# Add new client data to the Wireguard configuration file
cat >> /etc/wireguard/wg0.conf << \EOF

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
PresharedKey = $CLIENT_PRESHARED_KEY
AllowedIPs = $CLIENT_IP4, $CLIENT_IP6
\EOF

# Restart Wireguard
systemctl stop wg-quick@wg0
systemctl start wg-quick@wg0

# Show QR config to display
qrencode -t ansiutf8 < ./$USERNAME.conf

# Show config file
echo "# Display $USERNAME.conf"
cat ./$USERNAME.conf

# Save QR config to png file
qrencode -t png -o ./$USERNAME.png < ./$USERNAME.conf
EOF
sed 's/\\//g' add-client > add-client.sh
rm -f add-client
chmod 755 add-client.sh
ln -s /etc/wireguard/add-client.sh /usr/bin/addwgclient
echo "net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1" > /etc/sysctl.d/wg.conf
sysctl --system
systemctl enable --now ufw
ufw allow 22/tcp
ufw allow $LISTENPORT/udp
ufw enable
systemctl enable wg-quick@wg0.service
systemctl start wg-quick@wg0.service