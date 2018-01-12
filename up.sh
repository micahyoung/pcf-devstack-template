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
        "openstack_authentication_url": "http://10.10.0.4:5000/v2.0",
        "openstack_username": "admin",
        "openstack_password": "password",
        "openstack_tenant": "demo",
        "openstack_region": "RegionOne",
        "openstack_security_group": "bosh",
        "keystone_version": "v2.0",
        "ignore_server_availability_zone": false,
        "openstack_key_pair_name": "bosh",
        "networking_model": "neutron",
        "ssh_private_key": "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA44kTjqdgpX4jdP/ZPpXv4zKh0yNP2pIIIAmdoQ3/WhoTRWlc\nHZ1P8qyrQiKG2L+iz1/7sEAcF1IFkOXs5X33u/UVibOzkGBLDfGjkpanAan2qdH9\nitLEKVPY2LyblHTsP6c6RwBqOchZVvKAkiZHvw1NyxqiZMPwlTgqtaaIXM1YGIgY\nmtFJ+JfQnHk9tm29mcTH8tuo8NFbV+HAtlLVcn1yPcY2qm8xQicEHCHvBAqJtHu0\nSxdGoJQkrPoMKEYPxyuzY5xTy1S9ArgeGgQ/geni7SNC8QdYsXLJ0Yv1F3ixSn7P\no8MrFBIHDdR+aWPDf1+OMjUPjpDF2f+z8KR/3QIDAQABAoIBAQCzX6/kSP0+2eb3\n6G6KEUew84xxV6gvJepz30C947wHewDwOnQdAJQzOn40P+XQX5rpIsDXHGNI2yd6\nKFiOPrUbHsXg7aLEUbU5g+IwwMVd4XCMRfg8BZYRAoGzs1RvP5GzSJD/wkr7zH7p\ntXk4PidXbRSD5jZZe8Jg0IuS8nsTtG2Tk6xRZzC6gMbLpIt0sD7EaUTblKXJoJ7s\nX2GI5tK/pQ06fWuLtdkXWiXe01HSyjUQ0mUsP8Msf61TLWNpEyElpQlNZJg4R9uN\nJbmeiDQQngajGy/Gs7G1ODmDgb/xXd/0DP8ap+zQBgwLswTQOyUfzjl98l/584/r\nsiO1G0CdAoGBAPGDi0X6OiUoJjWh414NA9Yi9mSCRPbZbuoPtw4V6admVviYwLOf\n6DOEDMRmp4r1JihcpByL9UiE2FHNmecJIZo4vq+3tRxvAaoJ+qvK0LW70ANJQg+J\nSBm/nQdIrja/befKjGdapT6ZJR7Ysk9W1pH5Z/0B1XBvW/Sl9pGCYzmHAoGBAPEu\n5MB8lv6Xx+Zw/5F5xx7LFemaIkGfFcaqnbvEZbF7P09s41oY6igTvRQ0QrzwvaSN\ndn6gZG1YxSUbP4xRLiZr0v0Mq3xUc1yZEo9HrPFN8SCcBFjhZlxv72IuWheJy9KF\n8VTUPP1Ay0g3hD2iS9cYRsqIRVm9imaLrzG+0ER7AoGBAJdjxtTJotMR1Mm/vd+B\ntwrvBZZBVmuKJo2P5kZtE/b8Hr5cOkcekJZiSwJ9+r4PJ6kbUUAXt1yK8XJtt/Br\n9+VNdrJ9LIkzSE7HTJuNWcDhhuXYcRF+E3UYeJ1NQO9Old07SUGsP3L62pr4aOV0\n4LHGLhoZoSqGk5TKx8G0gvBXAoGAI7zOGpObkCgPb98Ij5ba4X44RgAX2V9oS6LW\nco88flsD25IH8j7E26FpIAhKZ1LI1ww7JbJAj09bDw+FkBYrX3gUsHhjJK4i1fK8\npEx7nNnuw+U6Y60qjMHtV8AEi35YnF5Kj0ZPrzsdpBrN1pAo6rtnKfWdSRnj2yQR\nlq5uj+cCgYBS6dj/noYalrb8izifVX/YcDpHX/ppexnD3dGIRx/ZUDoQzRtcKESO\nX5xdkeyISESEgpY9Qf+V7wy/YS4V9schYbXMnRulP5xCuxmhjm1bTw3w6yc3RCzG\n4WeUesbrO/5ffHteVU01BGN8DLF3LjfwojBGheV8Y4pM1KtIKdfJyg==\n-----END RSA PRIVATE KEY-----",
        "api_ssl_cert": "-----BEGIN CERTIFICATE-----\nMIIDQzCCAiugAwIBAgIRAJE8SRinErUiv04dRh6hk3MwDQYJKoZIhvcNAQELBQAw\nMzEMMAoGA1UEBhMDVVNBMRYwFAYDVQQKEw1DbG91ZCBGb3VuZHJ5MQswCQYDVQQD\nEwJjYTAeFw0xODAxMTAxOTE0MzBaFw0xOTAxMTAxOTE0MzBaMDkxDDAKBgNVBAYT\nA1VTQTEWMBQGA1UEChMNQ2xvdWQgRm91bmRyeTERMA8GA1UEAxMIMTAuMC4wLjMw\nggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCx8FJoeaNCV2jpEP5os0h6\nwr4sPugXWzSqP6aSFxc3TBbKYz0VP7mJQdmrekf2RsFnRtCoAmUokGARRCYukaFU\n9h+iySi0x0z7SS5YW0fY8kt1bm6PHtpCYsNcalTUMf6Xaa5tcyGBSJXI9rjoD/PF\nZXHtIGCRGOZdw2Auck8k2NdB/5wk76Oppk065wAQrpClfHSubyVZLrGrIvpPQRyO\nB1Tohs1KP/Uw5dpKXZsVW4mOaJzeHjC/H67XY0/vA+bFQt5ooBZYTrXCYyVYTuNs\nZBenQU0+mRTOekjCYgL2nRG5REc0V3tTiKTTwNiE/ySV5EKZ6VoewIwMbwUK0Xnb\nAgMBAAGjTDBKMA4GA1UdDwEB/wQEAwIFoDATBgNVHSUEDDAKBggrBgEFBQcDATAM\nBgNVHRMBAf8EAjAAMBUGA1UdEQQOMAyHBAoAAAOHBKwSof4wDQYJKoZIhvcNAQEL\nBQADggEBADZEJBOirtuMvlJGdS52dNC5tLkq2m1asyw6HmWtDgnDAHRx/vykHfL4\nreRqHtGjVLliADndGHcbE0SWzXDa7POsigxMp65Pq7EFXxt8mhB2yD/UCfwrcBUP\nQCSyyERFLzaxQKtIWZAAPXOImfdh74ohPSUslWpJYTS2LHa+kXD3SNGPPU3TWxwl\nkEtddZoEyjApmyfHQpgDnzac1jTXwJxzt5LzYcq1rEmPDTMvBNZlaFsTWEf2OadK\n7P4SHnC4Icgpn+XfZ8v04V2AhbjDhuYIhgq1r+XIkbuyT3wgCEjShXrO2DgGV/yj\n8IEMTQHM0GvC9ieMgBec1bhS6tGyxJE=\n-----END CERTIFICATE-----"
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
                "iaas_identifier": "vsphere-network-name",
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
