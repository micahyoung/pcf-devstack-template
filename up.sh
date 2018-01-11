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
OPSMAN_VERSION=2.0.2
SRT_VERSION=2.0.1
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

  bin/om
    --target https://$OPSMAN_IP \
    --skip-ssl-validation \
    --username admin \
    --password password \
    configure-bosh \
      --iaas-configuration '{
        "identity_endpoint": "http://10.10.0.4:5000/v2.0",
        "keystone_version": "v2.0",
        "username": "admin",
        "password": "password",
        "tenant": "demo",
        "region": "RegionOne",
        "networking_model": "neutron",
        "security_group": "bosh",
        "key_pair_name": "bosh",
        "ssh_private_key": "-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA44kTjqdgpX4jdP/ZPpXv4zKh0yNP2pIIIAmdoQ3/WhoTRWlc
HZ1P8qyrQiKG2L+iz1/7sEAcF1IFkOXs5X33u/UVibOzkGBLDfGjkpanAan2qdH9
itLEKVPY2LyblHTsP6c6RwBqOchZVvKAkiZHvw1NyxqiZMPwlTgqtaaIXM1YGIgY
mtFJ+JfQnHk9tm29mcTH8tuo8NFbV+HAtlLVcn1yPcY2qm8xQicEHCHvBAqJtHu0
SxdGoJQkrPoMKEYPxyuzY5xTy1S9ArgeGgQ/geni7SNC8QdYsXLJ0Yv1F3ixSn7P
o8MrFBIHDdR+aWPDf1+OMjUPjpDF2f+z8KR/3QIDAQABAoIBAQCzX6/kSP0+2eb3
6G6KEUew84xxV6gvJepz30C947wHewDwOnQdAJQzOn40P+XQX5rpIsDXHGNI2yd6
KFiOPrUbHsXg7aLEUbU5g+IwwMVd4XCMRfg8BZYRAoGzs1RvP5GzSJD/wkr7zH7p
tXk4PidXbRSD5jZZe8Jg0IuS8nsTtG2Tk6xRZzC6gMbLpIt0sD7EaUTblKXJoJ7s
X2GI5tK/pQ06fWuLtdkXWiXe01HSyjUQ0mUsP8Msf61TLWNpEyElpQlNZJg4R9uN
JbmeiDQQngajGy/Gs7G1ODmDgb/xXd/0DP8ap+zQBgwLswTQOyUfzjl98l/584/r
siO1G0CdAoGBAPGDi0X6OiUoJjWh414NA9Yi9mSCRPbZbuoPtw4V6admVviYwLOf
6DOEDMRmp4r1JihcpByL9UiE2FHNmecJIZo4vq+3tRxvAaoJ+qvK0LW70ANJQg+J
SBm/nQdIrja/befKjGdapT6ZJR7Ysk9W1pH5Z/0B1XBvW/Sl9pGCYzmHAoGBAPEu
5MB8lv6Xx+Zw/5F5xx7LFemaIkGfFcaqnbvEZbF7P09s41oY6igTvRQ0QrzwvaSN
dn6gZG1YxSUbP4xRLiZr0v0Mq3xUc1yZEo9HrPFN8SCcBFjhZlxv72IuWheJy9KF
8VTUPP1Ay0g3hD2iS9cYRsqIRVm9imaLrzG+0ER7AoGBAJdjxtTJotMR1Mm/vd+B
twrvBZZBVmuKJo2P5kZtE/b8Hr5cOkcekJZiSwJ9+r4PJ6kbUUAXt1yK8XJtt/Br
9+VNdrJ9LIkzSE7HTJuNWcDhhuXYcRF+E3UYeJ1NQO9Old07SUGsP3L62pr4aOV0
4LHGLhoZoSqGk5TKx8G0gvBXAoGAI7zOGpObkCgPb98Ij5ba4X44RgAX2V9oS6LW
co88flsD25IH8j7E26FpIAhKZ1LI1ww7JbJAj09bDw+FkBYrX3gUsHhjJK4i1fK8
pEx7nNnuw+U6Y60qjMHtV8AEi35YnF5Kj0ZPrzsdpBrN1pAo6rtnKfWdSRnj2yQR
lq5uj+cCgYBS6dj/noYalrb8izifVX/YcDpHX/ppexnD3dGIRx/ZUDoQzRtcKESO
X5xdkeyISESEgpY9Qf+V7wy/YS4V9schYbXMnRulP5xCuxmhjm1bTw3w6yc3RCzG
4WeUesbrO/5ffHteVU01BGN8DLF3LjfwojBGheV8Y4pM1KtIKdfJyg==
-----END RSA PRIVATE KEY-----",
        "api_ssl_cert": "-----BEGIN CERTIFICATE-----
MIIDQzCCAiugAwIBAgIRAJE8SRinErUiv04dRh6hk3MwDQYJKoZIhvcNAQELBQAw
MzEMMAoGA1UEBhMDVVNBMRYwFAYDVQQKEw1DbG91ZCBGb3VuZHJ5MQswCQYDVQQD
EwJjYTAeFw0xODAxMTAxOTE0MzBaFw0xOTAxMTAxOTE0MzBaMDkxDDAKBgNVBAYT
A1VTQTEWMBQGA1UEChMNQ2xvdWQgRm91bmRyeTERMA8GA1UEAxMIMTAuMC4wLjMw
ggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCx8FJoeaNCV2jpEP5os0h6
wr4sPugXWzSqP6aSFxc3TBbKYz0VP7mJQdmrekf2RsFnRtCoAmUokGARRCYukaFU
9h+iySi0x0z7SS5YW0fY8kt1bm6PHtpCYsNcalTUMf6Xaa5tcyGBSJXI9rjoD/PF
ZXHtIGCRGOZdw2Auck8k2NdB/5wk76Oppk065wAQrpClfHSubyVZLrGrIvpPQRyO
B1Tohs1KP/Uw5dpKXZsVW4mOaJzeHjC/H67XY0/vA+bFQt5ooBZYTrXCYyVYTuNs
ZBenQU0+mRTOekjCYgL2nRG5REc0V3tTiKTTwNiE/ySV5EKZ6VoewIwMbwUK0Xnb
AgMBAAGjTDBKMA4GA1UdDwEB/wQEAwIFoDATBgNVHSUEDDAKBggrBgEFBQcDATAM
BgNVHRMBAf8EAjAAMBUGA1UdEQQOMAyHBAoAAAOHBKwSof4wDQYJKoZIhvcNAQEL
BQADggEBADZEJBOirtuMvlJGdS52dNC5tLkq2m1asyw6HmWtDgnDAHRx/vykHfL4
reRqHtGjVLliADndGHcbE0SWzXDa7POsigxMp65Pq7EFXxt8mhB2yD/UCfwrcBUP
QCSyyERFLzaxQKtIWZAAPXOImfdh74ohPSUslWpJYTS2LHa+kXD3SNGPPU3TWxwl
kEtddZoEyjApmyfHQpgDnzac1jTXwJxzt5LzYcq1rEmPDTMvBNZlaFsTWEf2OadK
7P4SHnC4Icgpn+XfZ8v04V2AhbjDhuYIhgq1r+XIkbuyT3wgCEjShXrO2DgGV/yj
8IEMTQHM0GvC9ieMgBec1bhS6tGyxJE=
-----END CERTIFICATE-----"
      }' \
;
#      --director-configuration '{
#        "ntp_servers_string": "10.0.0.1"
#      }' \
#      --security-configuration '{
#        "trusted_certificates": "some-trusted-certificates",
#        "vm_password_type": "generate"
#      }' \
#      --az-configuration '{
#        "availability_zones": [
#          {
#            "name": "nova",
#          }
#        ]
#      }' \
#      --network-configuration '{
#        "icmp_checks_enabled": false,
#        "networks": [
#          {
#            "name": "opsman-network",
#            "service_network": false,
#            "subnets": [
#              {
#                "iaas_identifier": "vsphere-network-name",
#                "cidr": "10.0.0.0/24",
#                "reserved_ip_ranges": "10.0.0.0-10.0.0.4",
#                "dns": "8.8.8.8",
#                "gateway": "10.0.0.1",
#                "availability_zones": [
#                  "az-1"
#                ]
#              }
#            ]
#          }
#          {
#            "name": "ert-network",
#            "service_network": false,
#            "subnets": [
#              {
#                "iaas_identifier": "vsphere-network-name",
#                "cidr": "10.0.4.0/24",
#                "reserved_ip_ranges": "10.0.4.0-10.0.4.4",
#                "dns": "8.8.8.8",
#                "gateway": "10.0.4.1",
#                "availability_zones": [
#                  "az-1",
#                  "az-2",
#                  "az-3"
#                ]
#              }
#            ]
#          }
#          {
#            "name": "services-network",
#            "service_network": false,
#            "subnets": [
#              {
#                "iaas_identifier": "vsphere-network-name",
#                "cidr": "10.0.8.0/24",
#                "reserved_ip_ranges": "10.0.8.0-10.0.8.4",
#                "dns": "8.8.8.8",
#                "gateway": "10.0.8.1",
#                "availability_zones": [
#                  "az-1",
#                  "az-2",
#                  "az-3"
#                ]
#              }
#            ]
#          }
#        ]
#      }' \
#      --network-assignment '{
#        "singleton_availability_zone": "az-1",
#        "network": "opsman-network"
#      }'

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
