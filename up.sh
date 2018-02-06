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
: ${OPENSTACK_HOST:?"!"}
: ${CONCOURSE_URL:?"!"}
: ${S3_ENDPOINT:?"!"}
: ${S3_ACCESS_KEY:?"!"}
: ${S3_SECRET_KEY:?"!"}
: ${S3_OUTPUT_BUCKET:?"!"}
: ${EXTERNAL_NET_NAME:?"!"}
: ${OPENSTACK_KEYPAIR_NAME:?"!"}
: ${OPENSTACK_KEYPAIR_BASE64:?"!"}
: ${SYSTEM_DOMAIN:?"!"}
: ${APPS_DOMAIN:?"!"}
: ${OPSMAN_PUBKEY:?"!"}
: ${OPSMAN_VOLUME_SIZE_GB:?"!"}
: ${OPSMAN_FQDN:?"!"}
: ${OPSMAN_ADMIN_USERNAME:?"!"}
: ${OPSMAN_ADMIN_PASSWORD:?"!"}
: ${OPSMAN_DECRYPT_PASSWORD:?"!"}
: ${HAPROXY_FQDN:?"!"}
: ${HAPROXY_IP:?"!"}
: ${HAPROXY_FORWARD_TLS:?"!"}
: ${HAPROXY_CA_BASE64:?"!"}
: ${APPSMAN_COMPANY_NAME:?"!"}
: ${MYSQL_MONITOR_EMAIL:?"!"}
: ${SAML_CERT_BASE64:?"!"}
: ${SAML_KEY_BASE64:?"!"}
: ${IGNORE_SSL_CERT_VERIFICATION:?"!"}
: ${SKIP_CERT_VERIFY:?"!"}
ERT_MAJOR_MINOR_VERSION='2\.[0-9\]+\.[0-9]+$'
OPSMAN_MAJOR_MINOR_VERSION='2\.[0-9\]+\.[0-9]+$'
PCF_PIPELINES_VERSION=v0.23.0
OPENSTACK_AUTH_URL=http://$OPENSTACK_HOST/v3
OPENSTACK_API_VERSION=3
OPENSTACK_RESOURCE_PREFIX=devstack
OPENSTACK_PROJECT=demo
OPENSTACK_USERNAME=demo
OPENSTACK_PASSWORD=password
OPENSTACK_TENANT=demo
OPENSTACK_REGION=RegionOne
OPENSTACK_USER_DOMAIN_NAME=Default
OPENSTACK_NETWORKING_MODEL=neutron
INFRA_NETWORK_NAME=${OPENSTACK_RESOURCE_PREFIX}-infra-net
INFRA_NETWORK_DNS=8.8.8.8
INFRA_NETWORK_AZS=nova
SERVICES_NETWORK_NAME=${OPENSTACK_RESOURCE_PREFIX}-services-net
SERVICES_NETWORK_DNS=8.8.8.8
SERVICES_NETWORK_AZS=nova
ERT_NETWORK_NAME=${OPENSTACK_RESOURCE_PREFIX}-ert-net
ERT_NETWORK_DNS=8.8.8.8
ERT_NETWORK_AZS=nova
DYNAMIC_NETWORK_NAME=${OPENSTACK_RESOURCE_PREFIX}-dynamic-services-net
DYNAMIC_NETWORK_DNS=8.8.8.8
DYNAMIC_NETWORK_AZS=nova
SECURITY_GROUP=devstack
SINGLETON_AZ=nova
AZ1=nova
NTP_SERVERS=pool.ntp.org
ICMP_CHECKS_ENABLED=false
DIEGO_CELL_INSTANCES=1
SYSLOG_ADAPTER_INSTANCES=1
SYSLOG_SCHEDULER_INSTANCES=1
MYSQL_MONITOR_INSTANCES=0

export OS_PROJECT_NAME=$OPENSTACK_PROJECT
export OS_USERNAME=$OPENSTACK_USERNAME
export OS_PASSWORD=$OPENSTACK_PASSWORD
export OS_AUTH_URL=http://$OPENSTACK_HOST/v2.0
set -x

OPENSTACK_PROJECT_ID=$(openstack project show $OPENSTACK_PROJECT -c id -f value)
EXTERNAL_NET_ID=$(openstack network show $EXTERNAL_NET_NAME -c id -f value)

mkdir -p bin
PATH=$PATH:$(pwd)/bin

if ! [ -f bin/pivnet ]; then
  #curl -L "https://github.com/pivotal-cf/pivnet-cli/releases/download/v0.0.49/pivnet-darwin-amd64-0.0.49" > bin/pivnet
  curl -L "https://github.com/pivotal-cf/pivnet-cli/releases/download/v0.0.49/pivnet-linux-amd64-0.0.49" > bin/pivnet
  chmod +x bin/pivnet
fi

bin/pivnet login --api-token=$PIVNET_API_TOKEN

if ! [ -f bin/yaml-patch ]; then
  #curl -L "https://github.com/krishicks/yaml-patch/releases/download/v0.0.10/yaml_patch_darwin" > bin/yaml-patch
  curl -L "https://github.com/krishicks/yaml-patch/releases/download/v0.0.10/yaml_patch_linux" > bin/yaml-patch
  chmod +x bin/yaml-patch
fi

if ! [ -f bin/fly ]; then
  curl -L "$CONCOURSE_URL/api/v1/cli?arch=amd64&platform=linux" > bin/fly
  chmod +x bin/fly
fi

if ! [ -d bin/pcf-pipelines ]; then
  bin/pivnet \
    download-product-files \
    --product-slug=pcf-automation \
    --release-version=$PCF_PIPELINES_VERSION \
    --glob=pcf-pipelines-*.tgz \
    --download-dir=bin/ \
    --accept-eula \
  ;

  tar -xf bin/pcf-pipelines-*.tgz -C bin/
  rm bin/pcf-pipelines-*.tgz
fi

cat > state/add-pcf-pipelines-git-version.yml <<EOF
- op: add
  path: /resources/name=pcf-pipelines/source/tag_filter
  value: $PCF_PIPELINES_VERSION
EOF

cat > state/add-route53-domain-push.yml <<EOF
- op: add
  path: /groups/1/jobs/1
  value: set-fqdn-ips
- op: add
  path: /jobs/2
  value: 
    name: set-fqdn-ips
    serial_groups: [infra]
    plan:
    - aggregate:
      - get: terraform-state
        passed: [create-infrastructure]
        trigger: true
    - task: set-fqdn-ips
      config:
        platform: linux
        image_resource:
          type: docker-image
          source:
            repository: czero/rootfs
        inputs:
        - name: terraform-state
        params:
          AWS_ACCESS_KEY_ID: $S3_ACCESS_KEY
          AWS_SECRET_ACCESS_KEY: $S3_SECRET_KEY
          DOMAIN: $SYSTEM_DOMAIN
          OPSMAN_FQDN: $OPSMAN_FQDN
          HAPROXY_FQDN: $HAPROXY_FQDN
        run:
          path: /bin/bash
          args:
          - -c
          - |
            #!/bin/bash

            HAPROXY_IP=\$(jq -r '.modules[0].outputs.haproxy_floating_ip.value' terraform-state/terraform.tfstate)
            OPSMAN_IP=\$(jq -r '.modules[0].outputs.opsman_floating_ip.value' terraform-state/terraform.tfstate)
            echo HA_PROXY_IP: \$HAPROXY_IP
            echo OPSMAN_IP: \$OPSMAN_IP

            ZONES_JSON=\$(aws route53 list-hosted-zones-by-name --dns-name \$DOMAIN)
            HOSTED_ZONE=\$(jq -r '.HostedZones[0].Id' <(echo \$ZONES_JSON))

            read -r -d '' BATCH_JSON << EOJ
            {
              "Changes": [
                 {
                   "Action": "UPSERT",
                   "ResourceRecordSet": {
                     "Name": "\$HAPROXY_FQDN",
                     "ResourceRecords": [
                         {
                             "Value": "\$HAPROXY_IP"
                         }
                     ],
                     "Type": "A",
                     "TTL": 60
                   }
                 },
                 {
                   "Action": "UPSERT",
                   "ResourceRecordSet": {
                     "Name": "\$OPSMAN_FQDN",
                     "ResourceRecords": [
                         {
                             "Value": "\$OPSMAN_IP"
                         }
                     ],
                     "Type": "A",
                     "TTL": 60
                   }
                 }
              ]
            }
            EOJ

            jq '.' <(echo  \$BATCH_JSON)

            aws route53 change-resource-record-sets --hosted-zone-id=\$HOSTED_ZONE --change-batch=file://<(echo \$BATCH_JSON)

            while sleep 1; do
              if [ "\$OPSMAN_IP" = "\$(dig +short \$OPSMAN_FQDN)" ] && \
                 [ "\$HAPROXY_IP" = "\$(dig +short \$HAPROXY_FQDN)" ]; then
                exit
              fi

              echo waiting for DNS to update
              echo \$(dig +short \$OPSMAN_FQDN) != \$OPSMAN_IP 
              echo \$(dig +short \$HAPROXY_FQDN) != \$HAPROXY_IP 
            done
EOF

cat > state/remove-worker-tags-opsfile.yml <<EOF
- op: remove
  path: /jobs/name=upload-opsman-image/plan/0/aggregate/get=ops-manager/tags
- op: remove
  path: /jobs/name=upload-opsman-image/plan/task=upload/tags
- op: remove
  path: /jobs/name=create-infrastructure/ensure/tags
- op: remove
  path: /jobs/name=create-infrastructure/plan/0/aggregate/get=pcf-pipelines/tags
- op: remove
  path: /jobs/name=create-infrastructure/plan/0/aggregate/get=terraform-state/tags
- op: remove
  path: /jobs/name=create-infrastructure/plan/0/aggregate/get=ops-manager/tags
- op: remove
  path: /jobs/name=create-infrastructure/plan/task=create-infrastructure/tags
- op: remove
  path: /jobs/name=configure-director/plan/0/aggregate/get=pcf-pipelines/tags
- op: remove
  path: /jobs/name=configure-director/plan/0/aggregate/get=ops-manager/tags
- op: remove
  path: /jobs/name=configure-director/plan/task=configure-auth/tags
- op: remove
  path: /jobs/name=configure-director/plan/task=configure/tags
- op: remove
  path: /jobs/name=deploy-director/plan/0/aggregate/get=pcf-pipelines/tags
- op: remove
  path: /jobs/name=deploy-director/plan/0/aggregate/get=ops-manager/tags
- op: remove
  path: /jobs/name=deploy-director/plan/task=apply-changes/tags
- op: remove
  path: /jobs/name=upload-ert/plan/0/aggregate/get=pcf-pipelines/tags
- op: remove
  path: /jobs/name=upload-ert/plan/0/aggregate/get=pivnet-product/tags
- op: remove
  path: /jobs/name=upload-ert/plan/0/aggregate/get=ops-manager/tags
- op: remove
  path: /jobs/name=upload-ert/plan/task=upload-tile/tags
- op: remove
  path: /jobs/name=upload-ert/plan/task=stage-tile/tags
- op: remove
  path: /jobs/name=configure-ert/plan/0/aggregate/get=pcf-pipelines/tags
- op: remove
  path: /jobs/name=configure-ert/plan/0/aggregate/get=pivnet-product/tags
- op: remove
  path: /jobs/name=configure-ert/plan/task=configure/tags
- op: remove
  path: /jobs/name=deploy-ert/plan/0/aggregate/get=pcf-pipelines/tags
- op: remove
  path: /jobs/name=deploy-ert/plan/0/aggregate/get=pivnet-product/tags
- op: remove
  path: /jobs/name=deploy-ert/plan/task=deploy/tags
- op: remove
  path: /jobs/name=wipe-env/ensure/tags
- op: remove
  path: /jobs/name=wipe-env/plan/0/aggregate/get=pcf-pipelines/tags
- op: remove
  path: /jobs/name=wipe-env/plan/0/aggregate/get=terraform-state/tags
- op: remove
  path: /jobs/name=wipe-env/plan/task=wipe-env/tags
EOF

cat > state/install-pcf-params.yml <<EOF
# Whether to allow SSH access to application instances
allow_app_ssh_access: false

## Authentication type needed. SAML is not presently supported.
authentication_mode: internal # (internal|ldap) If ldap, specify ldap configuration below.
first_name_attribute:
group_search_base:
group_search_filter:
last_name_attribute:
ldap_pwd:
ldap_url:
ldap_user:
mail_attribute_name:
search_base:
search_filter:

# AZ configuration for Ops Director
az_01_name: $AZ1
#az_02_name: CHANGEME
#az_03_name: CHANGEME

# TODO: Add ability to use s3 blobstore
bosh_blobstore_type: local   # Type of blobstore to use (local)

# TODO: Add ability to use external DB
bosh_database_type: internal # Type of DB to use (internal)

# Ciphers
# An ordered, colon-delimited list of Golang supported TLS cipher suites in OpenSSL format.
# Operators should verify that these are supported by any clients or downstream components that will initiate TLS handshakes with the Router/HAProxy.
# The recommended settings are filled in below, change as necessary.
haproxy_tls_ciphers: "DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384"
router_tls_ciphers: "ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384"

# Company Name for Apps Manager
company_name: $APPSMAN_COMPANY_NAME

# C2C Networking network CIDR
container_networking_nw_cidr: 10.255.0.0/16

# For credhub integration, replace dummy values in the following structure
# and set the number of credhub instances in resource config to 2
credhub_encryption_keys: |
  - name: dummy encryption key 1
    key:
      secret: foobar
    primary: true
  - name: encryption key 2
    key:
      secret: bazqux

default_quota_max_number_services: 1000

default_quota_memory_limit_mb: 10240

# Disable HTTP on gorouters (true|false)
disable_http_proxy: false

# If true, disable insecure cookies on the router.
disable_insecure_cookies: false

## Domain names
apps_domain: $APPS_DOMAIN    # The Apps domain for your PCF environment e.g. cfapps.pcf.example.com.
system_domain: $SYSTEM_DOMAIN # The System domain for your PCF environment e.g sys.pcf.example.com.

# TODO: Allow multiple DNS servers for each net (currently only 1 can be set)
# Dynamic Services Network
dynamic_services_dns: $DYNAMIC_NETWORK_DNS
dynamic_services_gateway: 10.4.0.1
dynamic_services_network: $DYNAMIC_NETWORK_NAME
dynamic_services_nw_azs: $DYNAMIC_NETWORK_AZS
dynamic_services_reserved_ip_ranges: 10.4.0.0-10.4.0.9
dynamic_services_subnet_cidr: 10.4.0.0/24

# PCF Elastic Runtime minor version to track
ert_major_minor_version: $ERT_MAJOR_MINOR_VERSION

# AZ to use for deployment of ERT Singleton jobs
ert_singleton_job_az: $SINGLETON_AZ

# TODO: Allow multiple DNS servers for each net (currently only 1 can be set)
# ERT Network
ert_dns: $ERT_NETWORK_DNS
ert_gateway: 10.2.0.1
ert_network: $ERT_NETWORK_NAME
ert_nw_azs: $ERT_NETWORK_AZS
ert_reserved_ip_ranges: 10.2.0.0-10.2.0.9
ert_subnet_cidr: 10.2.0.0/24

# Set this to your floating IP network
external_network: $EXTERNAL_NET_NAME

# Set this to your floating IP network's id
external_network_id: $EXTERNAL_NET_ID

# Applications Network Maximum Transmission Unit bytes
garden_network_mtu: 1454

# Only change this if you need to avoid address collision with a third-party service on the same subnet.
garden_network_pool_cidr: 10.254.0.0/22

# HAProxy will use the CA provided to verify the certificates provided by the router.
haproxy_backend_ca: !!binary $HAPROXY_CA_BASE64

# Floating IPs allocated to HAProxy on OpenStack
haproxy_floating_ips: $HAPROXY_IP

# If enabled HAProxy will forward all requests to the router over TLS (enable|disable)
haproxy_forward_tls: $HAPROXY_FORWARD_TLS

# IaaS configuration for Ops Director
disable_dhcp: false     # If true, disable DHCP
ignore_server_az: false # If true, set the volume AZ to the default AZ.

# Network configuration for Ops Director
icmp_checks_enabled: $ICMP_CHECKS_ENABLED    # Enable or disable ICMP checks

# Whether to disable SSL cert verification for this environment
ignore_ssl_cert_verification: $IGNORE_SSL_CERT_VERIFICATION

# TODO: Allow multiple DNS servers for each net (currently only 1 can be set)
# Infra Network
infra_dns: $INFRA_NETWORK_DNS
infra_gateway: 10.1.0.1
infra_network: $INFRA_NETWORK_NAME
infra_nw_azs: $INFRA_NETWORK_AZS
infra_reserved_ip_ranges: 10.1.0.0-10.1.0.9
infra_subnet_cidr: 10.1.0.0/24

# Instances
## Default resource configuration
## these resources can take any parameter made available in
## the ops manager API ( https://<your-ops-man/docs#configuring-resources-for-a-job )
backup_prepare_instances: 0
clock_global_instances: 1
cloud_controller_instances: 1
cloud_controller_worker_instances: 1
consul_server_instances: 1
credhub_instances: 0
diego_brain_instances: 1
diego_cell_instances: $DIEGO_CELL_INSTANCES
diego_database_instances: 1
doppler_instances: 1
ha_proxy_instances: 1
loggregator_trafficcontroller_instances: 1
mysql_instances: 1
mysql_monitor_instances: $MYSQL_MONITOR_INSTANCES
mysql_proxy_instances: 1
nats_instances: 1
nfs_server_instances: 1
router_instances: 1
syslog_adapter_instances: $SYSLOG_ADAPTER_INSTANCES
syslog_scheduler_instances: $SYSLOG_SCHEDULER_INSTANCES
tcp_router_instances: 1
uaa_instances: 1

# Whether or not the ERT VMs are internet connected.
internet_connected: true

# IPs
ha_proxy_ips:           # Comma-separated list of static IPs
mysql_static_ips:       # Comma-separated list of static IPs
router_static_ips:      # Comma-separated list of static IPs
ssh_static_ips:         # Comma-separated list of static IPs
tcp_router_static_ips:  # Comma-separated list of static IPs

# Loggegrator Port. Default is 443
loggregator_endpoint_port:

# Max threads count for deploying VMs
max_threads: 30

# IP address of Pivotal Ops Metrics if installed
metrics_ip:

# Whether to enable MySQL backups. (disable|s3|scp)
mysql_backups: disable

# S3 backup config params (leave empty values if you're not using s3)
mysql_backups_s3_access_key_id:
mysql_backups_s3_bucket_name:
mysql_backups_s3_bucket_path:
mysql_backups_s3_cron_schedule:
mysql_backups_s3_endpoint_url:
mysql_backups_s3_secret_access_key:

# SCP backup config params (leave empty values if you're not using scp)
mysql_backups_scp_cron_schedule:
mysql_backups_scp_destination:
mysql_backups_scp_key:
mysql_backups_scp_port:
mysql_backups_scp_server:
mysql_backups_scp_user:

# Email address to receive MySQL monitor notifications
mysql_monitor_email: $MYSQL_MONITOR_EMAIL

networking_poe_ssl_certs:
# networking_poe_ssl_certs: |
#  - name: Point of Entry Certificate 1
#    certificate:
#      cert_pem: |
#        -----BEGIN EXAMPLE CERTIFICATE-----
#        ...
#        -----END EXAMPLE CERTIFICATE-----
#      private_key_pem: |
#        -----BEGIN EXAMPLE CERTIFICATE-----
#        ...
#        -----END EXAMPLE CERTIFICATE-----
#  - name: PoE certificate 2
#    certificate:
#      cert_pem: |
#        -----BEGIN EXAMPLE CERTIFICATE-----
#        ...
#        -----END EXAMPLE CERTIFICATE-----
#      private_key_pem: |
#        -----BEGIN EXAMPLE RSA PRIVATE KEY-----
#        ...
#        -----END EXAMPLE RSA PRIVATE KEY-----

# Comma-separated list of NTP servers to use for VMs deployed by BOSH
ntp_servers: $NTP_SERVERS

# Decryption password for Ops Manager exported settings
om_decryption_pwd: $OPSMAN_DECRYPT_PASSWORD

# Either opsman_client_id/opsman_client_secret or opsman_admin_username/opsman_admin_password needs to be specified
opsman_admin_password: $OPSMAN_ADMIN_PASSWORD # Password for Ops Manager admin account
opsman_admin_username: $OPSMAN_ADMIN_USERNAME # Username for Ops Manager admin account
opsman_client_id:                         # Client ID for Ops Manager admin account
opsman_client_secret:                     # Client Secret for Ops Manager admin account

# Ops Manager VM Settings
opsman_domain_or_ip_address: $OPSMAN_FQDN # FQDN to access Ops Manager without protocol (will use https), ex: opsmgr.example.com
opsman_flavor: m1.xlarge                  # Ops man VM flavor
opsman_image: ops-manager                 # Prefix for the ops man glance image

# PCF Ops Manager minor version to track
opsman_major_minor_version: $OPSMAN_MAJOR_MINOR_VERSION

# The public key of your opsman key
opsman_public_key: $OPSMAN_PUBKEY

# OpsMan VM disk size in GB
opsman_volume_size: $OPSMAN_VOLUME_SIZE_GB

# These are simply the project users credentials, downloaded from Horizon.
# The pre_os_cacert is the root CA cert, only needed if the openstack API's
# are fronted by a self-signed SSL certificate.
os_auth_url: $OPENSTACK_AUTH_URL
os_identity_api_version: $OPENSTACK_API_VERSION
os_interface: public
os_networking_model: $OPENSTACK_NETWORKING_MODEL
os_password: $OPENSTACK_PASSWORD
os_project_id: $OPENSTACK_PROJECT_ID
os_project_name: $OPENSTACK_PROJECT
os_region_name: $OPENSTACK_REGION
os_tenant: $OPENSTACK_TENANT
os_user_domain_name: $OPENSTACK_USER_DOMAIN_NAME
os_username: $OPENSTACK_USERNAME
pre_os_cacert: # Set if needed (see above)

os_keypair_name: $OPENSTACK_KEYPAIR_NAME # Keypair to use for bosh VMs
os_private_key: !!binary $OPENSTACK_KEYPAIR_BASE64

# The following should be set to a unique prefix. It will be used to prefix all
# the terraform resources created by the pipeline
os_resource_prefix: $OPENSTACK_RESOURCE_PREFIX

## Wildcard domain certs go here
pcf_ert_saml_cert: !!binary $SAML_CERT_BASE64
pcf_ert_saml_key: !!binary $SAML_KEY_BASE64

# Pivnet token for downloading resources from Pivnet. Find this token at https://network.pivotal.io/users/dashboard/edit-profile
pivnet_token: $PIVNET_API_TOKEN

# Whether to enable BOSH VM resurrector
resurrector_enabled: false

# Enable/disable route services (enable|disable)
route_services: disable

# Request timeout for gorouter
router_request_timeout_in_seconds: 900

# Optional - these certificates can be used to validate the certificates from incoming client requests.
# All CA certificates should be appended together into a single collection of PEM-encoded entries.
routing_custom_ca_certificates:

# Support for the X-Forwarded-Client-Cert header. Possible values: (load_balancer|ha_proxy|router)
routing_tls_termination: load_balancer

# S3 access credentials for storing terraform state.
s3_endpoint: $S3_ENDPOINT
s3_output_bucket: $S3_OUTPUT_BUCKET
tf_aws_access_key: $S3_ACCESS_KEY
tf_aws_secret_key: $S3_SECRET_KEY

# Setting appropriate Application Security Groups is critical for a secure
# deployment. Change the value of the param below to "X" to acknowledge that
# once the Elastic Runtime deployment completes, you will review and set the
# appropriate application security groups.
# See https://docs.pivotal.io/pivotalcf/opsguide/app-sec-groups.html
security_acknowledgement: X

# Security configuration for Ops Director
trusted_certificates:         # Optional. Trusted certificates to be deployed along with all VM's provisioned by BOSH
vm_password_type: generate    # 'generate' or 'bosh_default'

# Name of security group created by terraform
security_group: $SECURITY_GROUP

# TODO: Allow multiple DNS servers for each net (currently only 1 can be set)
# Services Network
services_dns: $SERVICES_NETWORK_DNS
services_gateway: 10.3.0.1
services_network: $SERVICES_NETWORK_NAME
services_nw_azs: $SERVICES_NETWORK_AZS
services_reserved_ip_ranges: 10.3.0.0-10.3.0.9
services_subnet_cidr: 10.3.0.0/24

# If true, disable SSL certificate verification for this environment.
skip_cert_verify: $SKIP_CERT_VERIFY

# If smtp_address is configured, smtp_from, smtp_port, smtp_user, smtp_pwd,
# smtp_enable_starttls_auto, and smtp_auth_mechanism must also be set.
smtp_address:
smtp_auth_mechanism: # (none|plain|cram-md5)
smtp_enable_starttls_auto: true
smtp_from:
smtp_port:
smtp_pwd:
smtp_user:

## Syslog endpoint configuration goes here
# Optional. If syslog_host is specified, syslog_port, syslog_protocol,
# syslog_drain_buffer_size, and enable_security_event_logging must be set.
enable_security_event_logging: false
syslog_drain_buffer_size: 10000
syslog_host:
syslog_port:
syslog_protocol:

# Enable/disable TCP routing (enable|disable)
tcp_routing: disable

# A comma-separated list of ports and hyphen-separated port ranges, e.g. 52135,34000-35000,23478
tcp_routing_ports:
EOF

if ! [ "72:30:20:122880:20" = "$(openstack quota show $OPENSTACK_PROJECT -f value -c cores -c instances -c networks -c ram -c volumes | paste -s -d:)" ]; then
  openstack quota set $OPENSTACK_PROJECT \
   --cores 72     \
   --instances 30 \
   --networks 20  \
   --ram 122880   \
   --volumes 20   \
  ;
fi

if ! grep -q $HAPROXY_IP <(openstack floating ip list -f value -c 'Floating IP Address'); then
  floating ip  create --floating-ip-address $HAPROXY_IP $EXTERNAL_NET_NAME
fi

PATCHED_PIPELINE=$(
  yaml-patch \
    -o state/add-pcf-pipelines-git-version.yml \
    -o state/remove-worker-tags-opsfile.yml \
    -o state/add-route53-domain-push.yml \
    < bin/pcf-pipelines/install-pcf/openstack/pipeline.yml
)

fly --target c login --concourse-url $CONCOURSE_URL

fly --target c set-pipeline \
  --pipeline install-pcf \
  --config <(echo "$PATCHED_PIPELINE") \
  --load-vars-from state/install-pcf-params.yml \
  --non-interactive \
  ;

fly --target c unpause-pipeline --pipeline install-pcf
