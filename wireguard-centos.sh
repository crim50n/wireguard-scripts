#!/bin/bash
yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
curl -o /etc/yum.repos.d/jdoss-wireguard-epel-7.repo https://copr.fedorainfracloud.org/coprs/jdoss/wireguard/repo/epel-7/jdoss-wireguard-epel-7.repo
yum -y install wireguard-dkms wireguard-tools qrencode
mkdir -p /etc/wireguard
cd /etc/wireguard
SUBNET4="10.4.0."
SUBNET6="fd00:4::"
SRVADDR4="10.4.0.1/24"
SRVADDR6="fd00:4::1/48"
LISTENPORT="51820"
DNSSERVER="1.1.1.1"
cat <<EOF > vpn_subnet.var
$SUBNET4
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
read VPN_SUBNET < ./vpn_subnet.var
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

CLIENT_IP="$VPN_SUBNET$OCTET_IP/32"

# Create a blank configuration file client 
cat > /etc/wireguard/clients/$USERNAME/$USERNAME.conf << \EOF
[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = $CLIENT_IP
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
AllowedIPs = $CLIENT_IP
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
firewall-cmd --permanent --zone=public --add-port=51820/udp
firewall-cmd --permanent --zone=public --add-masquerade
firewall-cmd --reload
systemctl enable wg-quick@wg0.service
systemctl start wg-quick@wg0.service
