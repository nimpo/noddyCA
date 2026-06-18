#!/bin/bash

# Script to Create a fake CA, issue certs for servers as specified in servers array with Domain: DOMAIN.
# Then secure copy each of the server's pfx, crt, and key files, and CAcert to REMOTEUSER@server.DOMAIN:UPLOADPATH
#
# Alter the following 5 declarations to suit: OR call this script with the env

if [ "$1" ]
then
  declare -a servers=("$@")
else
  declare -a servers=("test1" "test2")
fi
DOMAIN=${DOMAIN:-example.org}
CAName=${CAName:-Example-CA}
UPLOADPATH=${UPLOADPATH:-etc/}
REMOTEUSER=${REMOTEUSER:-$(id -un)}
MAKEWILDCARD=${MAKEWILDCARD:-no}

read -s -p "Set Password for the CA key: " CAPASSWD
echo
read -s -p "Set Password for the server PKCS12 files: " PASSWD
echo
echo
echo 'This script will now generate a 5000-day CA called "'"/CN=${CAName}"'",'
echo "and store it in ${CAName}-encrypted.key and ${CAName}.crt"
echo
echo "Then test for the following servers:"
for server in ${servers[@]}
do
  echo "  $server.$DOMAIN"
done
echo
echo "Then for each, generate a 4385-day certificate thus:"
for server in ${servers[@]}
do
  fqdn=$server.$DOMAIN
  echo '  A CSR requesting   "/CN='"$server.$DOMAIN"'" into: '"$fqdn-${CAName}.csr"
  echo '  A certificate with "/CN='"$server.$DOMAIN"'" into: '"$fqdn-${CAName}.crt"
  echo "    its key being stored unencrypted in:           $fqdn-${CAName}.key"
  echo "  A passwordless PKCS12 keystore:                  $fqdn-${CAName}.pfx"
  echo "  A password protected  PKCS12 keystore in:        $fqdn-${CAName}-pass.pfx"
  echo
done

read -p "Continue [y/n]? " CONT

[ "$CONT" = "y" ] || exit

MYTMPDIR=`mktemp -p. -d`
cd $MYTMPDIR || exit 1

echo "Storing the output files in `pwd`/$MYTMPDIR"
echo
sleep 2

openssl genrsa -out ${CAName}.key 4096
openssl rsa -aes256 -in ${CAName}.key -out ${CAName}-encrypted.key -passout "pass:$CAPASSWD"
openssl req -x509 -new -nodes -key ${CAName}.key -sha256 -days 5000 -out ${CAName}.crt -subj "/CN=${CAName}"

for server in ${servers[@]}
do
  fqdn=$server.$DOMAIN
echo " ! dig $fqdn +short |grep -q . && echo "Server $fqdn unresolvable " && continue "
  cat > dshubssl-ext.cnf <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
EOF
  if echo "$MAKEWILDCARD" | grep -qi "^y\(es\|\)$"
  then 
    echo "subjectAltName = DNS:$fqdn, DNS:*.$fqdn " >> dshubssl-ext.cnf
  else
    echo "subjectAltName = DNS:$fqdn" >> dshubssl-ext.cnf
  fi
  openssl req -new -nodes -out $fqdn-${CAName}.csr -newkey rsa:4096 -keyout $fqdn-${CAName}.key -subj "/CN=$fqdn"
  openssl x509 -req -in $fqdn-${CAName}.csr -CA ${CAName}.crt -CAkey ${CAName}.key -CAcreateserial -out $fqdn-${CAName}.crt -days 4385 -sha256 -extfile dshubssl-ext.cnf
  openssl pkcs12 -export -out $fqdn-${CAName}.pfx -inkey $fqdn-${CAName}.key -in $fqdn-${CAName}.crt -certfile ${CAName}.crt -passout pass:
  openssl pkcs12 -export -out $fqdn-${CAName}-pass.pfx -inkey $fqdn-${CAName}.key -in $fqdn-${CAName}.crt -certfile ${CAName}.crt -passout "pass:$PASSWD"
  rm $fqdn-${CAName}.csr dshubssl-ext.cnf
echo  ssh $REMOTEUSER@$fqdn mkdir -p $UPLOADPATH
echo  scp -p ${fqdn}-${CAName}.pfx ${fqdn}-${CAName}.key ${fqdn}-${CAName}.crt ${CAName}.crt ${REMOTEUSER}@${fqdn}:$UPLOADPATH
done

rm ${CAName}.key
