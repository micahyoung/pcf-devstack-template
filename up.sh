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
OPSMAN_GLOB="pcf-openstack-*.raw"
PAS_PRODUCT_NAME="cf"
PAS_VERSION=1.11.22
PAS_GLOB="cf-*.pivotal"
OPENSTACK_USERNAME=admin
OPENSTACK_PASSWORD=password
OPENSTACK_PROJECT=demo
OPSMAN_IP=10.0.0.3
OPSMAN_USERNAME=admin
OPSMAN_PASSWORD=password
OPSMAN_DECRYPTION_PASSWORD=password
PAS_STEMCELL_GLOB='bosh-stemcell-*-openstack-kvm-ubuntu-trusty-go_agent-raw.tgz' 
PAS_STEMCELL_VERSION=3445.19

set +o nounset
source ~stack/devstack/openrc $OPENSTACK_USERNAME $OPENSTACK_PROJECT
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
  bin/pivnet \
    download-product-files \
    --product-slug=ops-manager \
    --release-version=$OPSMAN_VERSION \
    --glob=$OPSMAN_GLOB \
    --download-dir=bin/ \
    --accept-eula \
  ;

  mv bin/$OPSMAN_GLOB bin/pcf-openstack.raw
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
      --username $OPSMAN_USERNAME \
      --password $OPSMAN_PASSWORD \
      --decryption-passphrase $OPSMAN_DECRYPTION_PASSWORD \
  ;
fi

if ! grep -q "p-bosh" <(bin/om -t https://$OPSMAN_IP -k -u $OPSMAN_USERNAME -p $OPSMAN_PASSWORD deployed-products); then
  bin/om \
    --target https://$OPSMAN_IP \
    --skip-ssl-validation \
    --username $OPSMAN_USERNAME \
    --password $OPSMAN_PASSWORD \
    configure-bosh \
      --iaas-configuration '{
        "openstack_authentication_url": "http://'$OPENSTACK_HOST'/v2.0",
        "openstack_username": "'$OPENSTACK_USERNAME'",
        "openstack_password": "'$OPENSTACK_PASSWORD'",
        "openstack_tenant": "'$OPENSTACK_PROJECT'",
        "openstack_region": "RegionOne",
        "openstack_security_group": "bosh",
        "keystone_version": "v2.0",
        "ignore_server_availability_zone": false,
        "openstack_key_pair_name": "bosh",
        "networking_model": "neutron",
        "ssh_private_key": "'"$SSH_PRIVATE_KEY"'",
        "api_ssl_cert": "'"$API_SSL_CERT"'"
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

  bin/om \
    --target https://$OPSMAN_IP \
    --username $OPSMAN_USERNAME \
    --password $OPSMAN_PASSWORD \
    --skip-ssl-validation \
    apply-changes \
  ;
fi

if ! [ -f bin/pas.pivotal ]; then
  bin/pivnet \
    download-product-files \
    --product-slug=elastic-runtime \
    --release-version=$PAS_VERSION \
    --glob=$PAS_GLOB \
    --download-dir=bin/ \
    --accept-eula \
  ;

  mv bin/$PAS_GLOB bin/pas.pivotal
fi

if ! grep -q $PAS_PRODUCT_NAME <(bin/om -t https://$OPSMAN_IP -k -u $OPSMAN_USERNAME -p $OPSMAN_PASSWORD available-products); then
  bin/om \
    --target https://$OPSMAN_IP \
    --username $OPSMAN_USERNAME \
    --password $OPSMAN_PASSWORD \
    --skip-ssl-validation \
    upload-product \
      --product bin/pas.pivotal \
  ;
fi

if ! [ -f bin/$PAS_STEMCELL_GLOB ]; then
  bin/pivnet \
    download-product-files \
    --product-slug=stemcells \
    --release-version=$PAS_STEMCELL_VERSION \
    --glob=$PAS_STEMCELL_GLOB \
    --download-dir=bin/ \
    --accept-eula \
  ;
fi

bin/om \
  --target https://10.0.0.3 \
  --skip-ssl-validation \
  --username admin \
  --password password \
  upload-stemcell \
    --stemcell bin/$PAS_STEMCELL_GLOB \
;

if ! grep -q $PAS_PRODUCT_NAME <(bin/om -t https://$OPSMAN_IP -k -u $OPSMAN_USERNAME -p $OPSMAN_PASSWORD deployed-products); then
  bin/om \
    --target https://$OPSMAN_IP \
    --username $OPSMAN_USERNAME \
    --password $OPSMAN_PASSWORD \
    --skip-ssl-validation \
    stage-product \
      --product-name $PAS_PRODUCT_NAME \
      --product-version $PAS_VERSION \
  ;

  bin/om \
    --target https://$OPSMAN_IP \
    --skip-ssl-validation \
    --username $OPSMAN_USERNAME \
    --password $OPSMAN_PASSWORD \
    configure-product \
      --product-name $PAS_PRODUCT_NAME \
      --product-properties '{
       ".cloud_controller.system_domain": {
         "value": "cf.young.io"
       },
       ".cloud_controller.apps_domain": {
         "value": "cf.young.io"
       },
       ".properties.networking_point_of_entry": {
         "value": "external_non_ssl"
       },
       ".uaa.service_provider_key_credentials": {
         "value": {
           "cert_pem": "-----BEGIN CERTIFICATE-----\nMIIDcTCCAlmgAwIBAgIUfOL0tPiyHdKhoGvrvobyPQmPdjkwDQYJKoZIhvcNAQEL\nBQAwHzELMAkGA1UEBhMCVVMxEDAOBgNVBAoMB1Bpdm90YWwwHhcNMTgwMTExMjEx\nMDI5WhcNMjAwMTExMjExMDI5WjA3MQswCQYDVQQGEwJVUzEQMA4GA1UECgwHUGl2\nb3RhbDEWMBQGA1UEAwwNKi5jZi55b3VuZy5pbzCCASIwDQYJKoZIhvcNAQEBBQAD\nggEPADCCAQoCggEBAKju8svxrLS8JMDk5iD7qShFWwMTL0Fv4GttzsdfERgeMslD\nCl0R0s9LhXbBQDf+6T6cY9OS1D3qCmIeJKAfvvKUA0HYO/WOhYgeA5la3JcR8Cec\nee5TTLcWZtaQxskVL1N3CVBnU8gzonkFG0qPec+ZjJDYMcsfMaPpUlynxBOMty9n\nwFcK1sWkAxNdupPsILOHmMlZE914oHAwuCHFJJdZX8KA5JrNVu6y15CttOh2719b\nxjP/rjq96YbCSU2lMUyloif3B1OpZV6YV7oRl7tXa9+duTlAfm/UMCF5Wk5C2NK5\nJL0L0mhS77Z6O6vNnltYgPFMmMUIfsSGRbODmP8CAwEAAaOBjDCBiTAOBgNVHQ8B\nAf8EBAMCB4AwHQYDVR0OBBYEFEKlPpdsa/mp4uhFarG3ajORdmHwMB0GA1UdJQQW\nMBQGCCsGAQUFBwMCBggrBgEFBQcDATAfBgNVHSMEGDAWgBQWiuFm5ce353jXotUt\nDRIJvzbdkTAYBgNVHREEETAPgg0qLmNmLnlvdW5nLmlvMA0GCSqGSIb3DQEBCwUA\nA4IBAQB4+xOfEiuA+jmKCCi6tFJbX6I7KSwjrSEW7W8Tgn/qNfTc6fY95HT66d/g\nB3MJuaHKhRPirOwU0MUjzLRvYwRrV3y6yg/1DY231Tjh+7/UBlQMK1yZzkmh4sid\nc5HIKw8zizMmVwmSFAG/FDzl42LSIjI1GPkAxO4nZnS3pX0Lfu93iO9X894IdjrR\nj3m5BW1rTdZXX4gk26M/55kgMkW5m9LgjwF5Z2OK/ZFkozanvVgoOvQnoWdUM2A6\nJvIKnE7PE/qRdgvxGQ/uYpPX9R6lgmH23DZ4kYpHSQqT36JEvuCLUWwMaMtvk2oJ\nRJcQSdTw7tYbYSITcQMgb+yRS4Qq\n-----END CERTIFICATE-----\n",
           "private_key_pem": "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAqO7yy/GstLwkwOTmIPupKEVbAxMvQW/ga23Ox18RGB4yyUMK\nXRHSz0uFdsFAN/7pPpxj05LUPeoKYh4koB++8pQDQdg79Y6FiB4DmVrclxHwJ5x5\n7lNMtxZm1pDGyRUvU3cJUGdTyDOieQUbSo95z5mMkNgxyx8xo+lSXKfEE4y3L2fA\nVwrWxaQDE126k+wgs4eYyVkT3XigcDC4IcUkl1lfwoDkms1W7rLXkK206HbvX1vG\nM/+uOr3phsJJTaUxTKWiJ/cHU6llXphXuhGXu1dr3525OUB+b9QwIXlaTkLY0rkk\nvQvSaFLvtno7q82eW1iA8UyYxQh+xIZFs4OY/wIDAQABAoIBABd6PdwCFlJ341O7\nfBARaYzjNqbSv7qEZdgIRriGicWkTMKTwpj0pSuR/1ZlvRsLHjdJXMZGnaCNKixA\nrC5kuxDTaTB5cLvLttsX8MAbVJTaNVoL8RYiFYNMZbZkIHxJqW4cGPtHoOkt4+KV\nxxkxn2gums52fVURXMC+6GdgGWvt5J4FcjfYfsuThVCcAAKsLlOfI+PM8heN72so\nRXHBxwPCIaqeCev6nA8IguIj165OVOYGTf+PWLT83AqXGET7YfcIMs745Pd+c1kd\n5yRk+uSS79AEb/t0PgXF9RBTTjBOBKz0HoGY6vDEMpbfb2YthTjPqJAWmLDPlWyX\nyTfZpQECgYEA2HaqvqmXTpApeC1QgWeHRfbjel+t67bHM1Z/HNTzIeI91P2pCdot\n/UHLMvLgDg//9WpFtW13r0x7GcKLr9vLsRW+irZC+0SNMqkBq+ee12nrES0Ikqj5\ne8G1CRKh59KdNQMWAVRv4QRaPfzn3ERxB/kqooD5yo6xVQh9vTsemeECgYEAx8nh\nw5SkBun5VkdD9WqPxisBOTNXkbUjrrpc7lPs2/0kYkYILwRm6PnKPstCo4ZV1RId\nfDRy2gtyyikWBvKz3el9sbg0VHPACgW3CxjTPCu1T0JfL1YIdWnEAXFRliJCrNWS\n2fHJzHdyIqEeK4dgw6BwnOZlq/AtY6FajhoZTt8CgYBMfgqyW42rZogw/ppfUC1e\nTPNv0BXOoQVdn+hFUP8l7yP4ezbb02zC/RgIRgllDsRdfhNqHGfZ24X4wWXJXDtr\ntYpizCt5TW00BMMhczUPXE+D/0zzPqEC2Z3Wue3a1PNWw2NoTuVGN9qH4zIwBUOI\nFMW7LSaYLLp/mQON9jFHIQKBgCgjsF8qCvZ0paqm8Mlq2m33D+zdGtfka8HcIXWk\nmO7t4hR4e4ZuvPpLzU1mawINqEsBs7jTlMuoBy0Eqi9FLcwE8EL3flQFWWzqDweE\nulPZeDjvXc5V26czU7TyfnDKe1jcI//zqxaQXPcGJdia/17uahGr3Ht56rSco2Pv\nbGxDAoGBANNDkTgUCePmJ1C7gZk0FXpKXbhZsRuI6q7y9cdIfVQRV2bzZeuVBway\ntrsFTDVgr1bFa6cB6br5Srecnbg7zFjuhFz8fJ4Jxss9PcWu8SQSyNr5uK9coxNY\nl511hqO1SUxU60iuRqUYXrQSPWMhqCHb9rEFAF3eK+tnVgm7r8A5\n-----END RSA PRIVATE KEY-----\n"
         }
       },
       ".properties.security_acknowledgement": {
         "value": "X"
       },
       ".mysql_monitor.recipient_email": {
         "value": "micah+cf@young.io"
       }
     }' \
     --product-network '{
       "singleton_availability_zone": {
         "name": "nova"
       },
       "other_availability_zones": [
         {
           "name": "nova"
         }
       ],
       "network": {
         "name": "private-network"
       }
     }' \
;
#     --product-resources '{
#       }' \

  bin/om \
    --target https://$OPSMAN_IP \
    --username $OPSMAN_USERNAME \
    --password $OPSMAN_PASSWORD \
    --skip-ssl-validation \
    apply-changes \
  ;
fi
