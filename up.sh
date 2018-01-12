#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if ! [ -d state ]; then
  exit "No State, exiting"
  exit 1
fi

source ./state/env.sh
: ${PIVNET_API_TOKEN:?"!"}
: ${NET_ID:?"!"}
: ${OPENSTACK_HOST:?"!"}
: ${SSH_PRIVATE_KEY:?"!"}
: ${API_SSL_CERT:?"!"}
OPSMAN_VERSION=1.11.18
SRT_VERSION=1.11.22
DEVSTACK_ENV=~stack/devstack/openrc
DEVSTACK_USER=admin
DEVSTACK_PROJECT=demo
OPSMAN_IP=10.0.0.3

set +o nounset
source ~stack/devstack/openrc admin demo
set -o nounset

set -x

mkdir -p bin
PATH=$PATH:$(pwd)/bin

if ! [ -f bin/pivnet ]; then
  curl -L "https://github.com/pivotal-cf/pivnet-cli/releases/download/v0.0.49/pivnet-linux-amd64-0.0.49" > bin/pivnet
  chmod +x bin/pivnet
fi

if ! [ -f bin/om ]; then
  curl -L "https://github.com/pivotal-cf/om/releases/download/0.29.0/om-linux" > bin/om
  chmod +x bin/om
fi

if ! [ -f bin/pcf-openstack.raw ]; then
  bin/pivnet download-product-files \
    --product-slug=ops-manager \
    --release-version=$OPSMAN_VERSION \
    --glob='*pcf-openstack-*.raw' \
    --download-dir=bin/ \
    --accept-eula \
  ;

  mv bin/pcf-openstack-*.raw bin/pcf-openstack.raw
fi

if ! grep -q opsman <(openstack flavor list -c Name -f value); then
  openstack flavor create \
    opsman \
    --public \
    --vcpus 1 \
    --ram 2048 \
    --disk 50 \
  ;
fi

if ! grep -q opsman/$OPSMAN_VERSION <(openstack image list -c Name -f value); then
  openstack image create \
    --file=bin/pcf-openstack.raw \
    opsman/$OPSMAN_VERSION \
  ;
fi

if ! grep -q opsman <(openstack security group list -c Name -f value); then
  openstack security group create opsman
  openstack security group rule create opsman --protocol=tcp --dst-port=443
fi

if ! grep -q opsman <(openstack server list -c Name -f value); then
  openstack server create \
    --image=opsman/$OPSMAN_VERSION \
    --flavor=opsman \
    --security-group=opsman \
    --key-name=bosh \
    --nic net-id=$NET_ID,v4-fixed-ip=$OPSMAN_IP \
    opsman \
  ;
fi

while ! grep -q "You are being" <(curl --max-time 1 -s -k https://$OPSMAN_IP); do
  sleep 10
done

if grep -q "Select an Authentication System" <(curl -s -k https://$OPSMAN_IP/setup); then
  bin/om \
    --target https://$OPSMAN_IP \
    --skip-ssl-validation \
    configure-authentication \
      --username admin \
      --password password \
      --decryption-passphrase password \
  ;
fi

  bin/om \
    --target https://$OPSMAN_IP \
    --skip-ssl-validation \
    --username admin \
    --password password \
    configure-bosh \
      --iaas-configuration '{
        "openstack_authentication_url": "http://'$OPENSTACK_HOST'/v2.0",
        "openstack_username": "admin",
        "openstack_password": "password",
        "openstack_tenant": "demo",
        "openstack_region": "RegionOne",
        "openstack_security_group": "bosh",
        "keystone_version": "v2.0",
        "ignore_server_availability_zone": false,
        "openstack_key_pair_name": "bosh",
        "networking_model": "neutron",
        "ssh_private_key": "'$SSH_PRIVATE_KEY'",
        "api_ssl_cert": "'$API_SSL_CERT'"
      }' \
      --director-configuration '{
        "ntp_servers_string": "pool.ntp.org"
      }' \
      --security-configuration '{
        "vm_password_type": "generate"
      }' \
      --az-configuration '{
        "availability_zones": [
          {
            "name": "nova"
          }
        ]
      }' \
      --networks-configuration '{
        "icmp_checks_enabled": true,
        "networks": [
          {
            "name": "private-network",
            "service_network": false,
            "subnets": [
              {
                "iaas_identifier": "'$NET_ID'",
                "cidr": "10.0.0.0/24",
                "reserved_ip_ranges": "10.0.0.0-10.0.0.4",
                "dns": "10.0.0.2",
                "gateway": "10.0.0.1",
                "availability_zones": [
                  "nova"
                ]
              }
            ]
          }
        ]
      }' \
      --network-assignment '{
        "singleton_availability_zone": "nova",
        "network": "private-network"
      }' \
  ;

#if grep -q "Select an Authentication System" <(curl -s -k https://$OPSMAN_IP/setup); then
#  bin/om \
#    --target https://$OPSMAN_IP \
#    --skip-ssl-validation \
#    --username admin \
#    --password password \
#    configure-authentication \
#    --decryption-passphrase password \
#  ;
#fi
