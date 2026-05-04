#!/bin/bash 
sudo apt install mkcert libnss3-tools
mkcert -install

mkcert "*.anode.com" anode.com
mv *.pem certs/

export CA_BUNDLE=$(mkcert -CAROOT)/rootCA.pem


#===================================


echo '127.0.0.1 sso.anode.com' | sudo tee -a /etc/hosts
echo '127.0.0.1 monitor.anode.com' | sudo tee -a /etc/hosts
echo '127.0.0.1 git.anode.com' | sudo tee -a /etc/hosts
echo '127.0.0.1 s3.anode.com' | sudo tee -a /etc/hosts
echo '127.0.0.1 portainer.anode.com' | sudo tee -a /etc/hosts
