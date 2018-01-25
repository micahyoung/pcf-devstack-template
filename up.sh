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
: ${CONCOURSE_URL:?"!"}
: ${S3_ACCESS_KEY:?"!"}
: ${S3_SECRET_KEY:?"!"}
: ${EXTERNAL_NET_ID:?"!"}
: ${EXTERNAL_NET_NAME:?"!"}
OPENSTACK_AUTH_URL=http://$OPENSTACK_HOST/v2.0
OPENSTACK_API_VERSION=2.0
OPENSTACK_RESOURCE_PREFIX=devstack
OPENSTACK_USERNAME=admin
OPENSTACK_PASSWORD=password
OPENSTACK_PROJECT=demo
OPENSTACK_REGION=RegionOne
OPSMAN_IP=10.0.0.3
OPSMAN_USERNAME=admin
OPSMAN_PASSWORD=password
OPSMAN_DECRYPTION_PASSWORD=password
INFRA_NETWORK_NAME=infra-network
SERVICES_NETWORK_NAME=services-network
ERT_NETWORK_NAME=ert-network
DYNAMIC_NETWORK_NAME=dynamic-network
SECURITY_GROUP=pcf

set -x

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
    --release-version=v0.22.0 \
    --glob=pcf-pipelines-*.tgz \
    --download-dir=bin/ \
    --accept-eula \
  ;

  tar -xf bin/pcf-pipelines-*.tgz -C bin/
  rm bin/pcf-pipelines-*.tgz
fi

cat > state/remote-worker-tags-opsfile.yml <<EOF
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
  path: /jobs/name=create-infrastructure/plan/0/aggregate/get=pivnet-opsmgr/tags
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

cat > state/bugfix-install-pcf-create-infrastructure-opsfile.yml <<EOF
- op: add
  path: /jobs/name=create-infrastructure/plan/task=create-infrastructure/input_mapping
  value:
    ops-manager: pivnet-opsmgr
EOF

cat > state/install-pcf-params.yml <<EOF
# Setting appropriate Application Security Groups is critical for a secure
# deployment. Change the value of the param below to "X" to acknowledge that
# once the Elastic Runtime deployment completes, you will review and set the
# appropriate application security groups.
# See https://docs.pivotal.io/pivotalcf/opsguide/app-sec-groups.html
security_acknowledgement: CHANGEME

pivnet_token: $PIVNET_API_TOKEN         # Pivnet token for downloading resources from Pivnet. Find this token at https://network.pivotal.io/users/dashboard/edit-profile
opsman_major_minor_version: ^1\.12\..*$ # PCF Ops Manager minor version to track
ert_major_minor_version: ^1\.12\..*$    # PCF Elastic Runtime minor version to track

# The following should be set to a unique prefix. It will be used to prefix all
# the terraform resources created by the pipeline
os_resource_prefix: $OPENSTACK_RESOURCE_PREFIX

# The S3 access credentials for storing terraform state.
s3_endpoint: $S3_ENDPOINT
s3_output_bucket: $S3_OUTPUT_BUCKET
tf_aws_access_key: $S3_ACCESS_KEY
tf_aws_secret_key: $S3_SECRET_KEY

# TODO: Allow multiple DNS servers for each net (currently only 1 can be set)

infra_network: $INFRA_NETWORK_NAME           # Infra Network Name
infra_subnet_cidr: 10.1.0.0/24               # Infra Network Subnet CIDR
infra_gateway: 10.1.0.1                      # Infra Network Gateway
infra_reserved_ip_ranges: 10.1.0.0-10.1.0.9  # Infra Network Reserved IP Ranges
infra_dns:                                   # Infra Network DNS Server
infra_nw_azs:                                # Infra Network AZs

ert_network: $ERT_NETWORK_NAME             # ERT Network Name
ert_subnet_cidr: 10.2.0.0/24               # ERT Network Subnet CIDR
ert_gateway: 10.2.0.1                      # ERT Network Gateway
ert_reserved_ip_ranges: 10.2.0.0-10.2.0.9  # ERT Network Reserved IP Ranges
ert_dns:                                   # ERT Network DNS Server
ert_nw_azs:                                # ERT Network AZs

services_network: $SERVICES_NETWORK_NAME        # Services Network Name
services_subnet_cidr: 10.3.0.0/24               # Services Network Subnet CIDR
services_gateway: 10.3.0.1                      # Services Network Gateway
services_reserved_ip_ranges: 10.3.0.0-10.3.0.9  # Services Network Reserved IP Ranges
services_dns:                                   # Services Network DNS Server
services_nw_azs:                                # Services Network AZs

dynamic_services_network: $DYNAMIC_NETWORK_NAME         # Dynamic Services Network Name
dynamic_services_subnet_cidr: 10.4.0.0/24               # Dynamic Services Network Subnet CIDR
dynamic_services_gateway: 10.4.0.1                      # Dynamic Services Network Gateway
dynamic_services_reserved_ip_ranges: 10.4.0.0-10.4.0.9  # Dynamic Services Network Reserved IP Ranges
dynamic_services_dns:                                   # Dynamic Services Network DNS Server
dynamic_services_nw_azs:                                # Dynamic Services Network AZs

container_networking_nw_cidr: 10.255.0.0/16 # C2C Networking network CIDR

external_network_id: $EXTERNAL_NET_ID # Set this to your floating IP network's id
external_network: $EXTERNAL_NET_NAME # Set this to your floating IP network

security_group: $SECURITY_GROUP    # Name of security group created by terraform

# These are simply the project users credentials, downloaded from Horizon.
# The pre_os_cacert is the root CA cert, only needed if the openstack API's
# are fronted by a self-signed SSL certificate.
os_auth_url: $OPENSTACK_AUTH_URL
os_identity_api_version: $OPENSTACK_API_VERSION
os_username: $OPENSTACK_USERNAME
os_password: $OPENSTACK_PASSWORD
os_user_domain_name: CHANGEME
os_project_name: $OPENSTACK_PROJECT
os_project_id: CHANGEME
os_tenant: CHANGEME
os_region_name: $OPENSTACK_REGION
os_interface: public
os_networking_model: CHANGEME (nova|neutron)
pre_os_cacert: # Set if needed (see above)

opsman_public_key: CHANGEME # The public key of your opsman key

opsman_volume_size: 100  # OpsMan VM disk size in GB

# AZ configuration for Ops Director
az_01_name: CHANGEME
#az_02_name: CHANGEME
#az_03_name: CHANGEME
ert_singleton_job_az: CHANGEME # AZ to use for deployment of ERT Singleton jobs

# Ops Manager VM Settings
opsman_image: ops-manager                 # Prefix for the ops man glance image
opsman_flavor: m1.xlarge                  # Ops man VM flavor
opsman_domain_or_ip_address: CHANGEME     # FQDN to access Ops Manager without protocol (will use https), ex: opsmgr.example.com

# Either opsman_client_id/opsman_client_secret or opsman_admin_username/opsman_admin_password needs to be specified
opsman_client_id: CHANGEME                # Client ID for Ops Manager admin account
opsman_client_secret: CHANGEME            # Client Secret for Ops Manager admin account
opsman_admin_username: admin              # Username for Ops Manager admin account
opsman_admin_password: CHANGEME           # Password for Ops Manager admin account

om_decryption_pwd: CHANGEME               # Decryption password for Ops Manager exported settings

# IaaS configuration for Ops Director
ignore_server_az: false # If true, set the volume AZ to the default AZ.
disable_dhcp: false     # If true, disable DHCP

# Security configuration for Ops Director
trusted_certificates:         # Optional. Trusted certificates to be deployed along with all VM's provisioned by BOSH
vm_password_type: generate    # 'generate' or 'bosh_default'

# Ops Director Config
ntp_servers: CHANGEME       # Comma-separated list of NTP servers to use for VMs deployed by BOSH
metrics_ip:                  # IP address of Pivotal Ops Metrics if installed
resurrector_enabled: false   # Whether to enable BOSH VM resurrector
max_threads: 30              # Max threads count for deploying VMs

# TODO: Add ability to use external DB
bosh_database_type: internal # Type of DB to use (internal)

# TODO: Add ability to use s3 blobstore
bosh_blobstore_type: local   # Type of blobstore to use (local)

os_keypair_name: CHANGEME   # Keypair to use for bosh VMs
os_private_key:  CHANGEME   # Private key for keypair

# Network configuration for Ops Director
icmp_checks_enabled: true    # Enable or disable ICMP checks

loggregator_endpoint_port:   # Loggegrator Port. Default is 443
company_name:                # Company Name for Apps Manager

## Syslog endpoint configuration goes here
# Optional. If syslog_host is specified, syslog_port, syslog_protocol,
# syslog_drain_buffer_size, and enable_security_event_logging must be set.
syslog_host:
syslog_port:
syslog_protocol:
enable_security_event_logging: false
syslog_drain_buffer_size: 10000

## Wildcard domain certs go here
# Optional. Will be generated if blank.
ssl_cert:

# Optional. Will be generated if blank.
ssl_private_key:
pcf_ert_saml_cert:
pcf_ert_saml_key:

haproxy_floating_ips: CHANGEME  # Floating IPs allocated to HAProxy on OpenStack
haproxy_forward_tls: enable      # If enabled HAProxy will forward all requests to the router over TLS (enable|disable)
haproxy_backend_ca: CHANGEME    # HAProxy will use the CA provided to verify the certificates provided by the router.

# An ordered, colon-delimited list of Golang supported TLS cipher suites in OpenSSL format.
# Operators should verify that these are supported by any clients or downstream components that will initiate TLS handshakes with the Router/HAProxy.
# The recommended settings are filled in below, change as necessary.
router_tls_ciphers: "ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384"
haproxy_tls_ciphers: "DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384"

# Disable HTTP on gorouters (true|false)
disable_http_proxy: false

## TCP routing and routing services
tcp_routing: disable                    # Enable/disable TCP routing (enable|disable)
tcp_routing_ports:                      # A comma-separated list of ports and hyphen-separated port ranges, e.g. 52135,34000-35000,23478 route_services: disable                 # Enable/disable route services (enable|disable)
route_services: disable                 # Enable/disable route services (enable|disable)
ignore_ssl_cert_verification: false     # Whether to disable SSL cert verification for this environment
garden_network_pool_cidr: 10.254.0.0/22 # Only change this if you need to avoid address collision with a third-party service on the same subnet.
garden_network_mtu: 1454                # Applications Network Maximum Transmission Unit bytes

# If smtp_address is configured, smtp_from, smtp_port, smtp_user, smtp_pwd,
# smtp_enable_starttls_auto, and smtp_auth_mechanism must also be set.
smtp_address:
smtp_from:
smtp_port:
smtp_user:
smtp_pwd:
smtp_enable_starttls_auto: true
smtp_auth_mechanism: # (none|plain|cram-md5)

## Authentication type needed. SAML is not presently supported.
authentication_mode: internal # (internal|ldap) If ldap, specify ldap configuration below.
ldap_url:
ldap_user:
ldap_pwd:
search_base:
search_filter:
group_search_base:
group_search_filter:
mail_attribute_name:
first_name_attribute:
last_name_attribute:

## Deployment domain names
system_domain: CHANGEME      # The System domain for your PCF environment e.g sys.pcf.example.com.
apps_domain:   CHANGEME      # The Apps domain for your PCF environment e.g. cfapps.pcf.example.com.

skip_cert_verify: false       # If true, disable SSL certificate verification for this environment.

disable_insecure_cookies: false # If true, disable insecure cookies on the router.

default_quota_memory_limit_mb: 10240
default_quota_max_number_services: 1000
allow_app_ssh_access: false             # Whether to allow SSH access to application instances

# Request timeout for gorouter
router_request_timeout_in_seconds: 900

ha_proxy_ips:           # Comma-separated list of static IPs
router_static_ips:      # Comma-separated list of static IPs
tcp_router_static_ips:  # Comma-separated list of static IPs
ssh_static_ips:         # Comma-separated list of static IPs
mysql_static_ips:       # Comma-separated list of static IPs

mysql_monitor_email: CHANGEME # Email address to receive MySQL monitor notifications
mysql_backups: disable         # Whether to enable MySQL backups. (disable|s3|scp)

# SCP backup config params (leave empty values if you're not using scp)
mysql_backups_scp_server:
mysql_backups_scp_port:
mysql_backups_scp_user:
mysql_backups_scp_key:
mysql_backups_scp_destination:
mysql_backups_scp_cron_schedule:

# S3 backup config params (leave empty values if you're not using s3)
mysql_backups_s3_endpoint_url:
mysql_backups_s3_bucket_name:
mysql_backups_s3_bucket_path:
mysql_backups_s3_access_key_id:
mysql_backups_s3_secret_access_key:
mysql_backups_s3_cron_schedule:

## Default resource configuration
## these resources can take any parameter made available in
## the ops manager API ( https://<your-ops-man/docs#configuring-resources-for-a-job )
consul_server_instances: 1
nats_instances: 1
nfs_server_instances: 1
mysql_proxy_instances: 1
mysql_instances: 1
backup_prepare_instances: 0
uaa_instances: 1
cloud_controller_instances: 1
ha_proxy_instances: 1
router_instances: 1
mysql_monitor_instances: 1
clock_global_instances: 1
cloud_controller_worker_instances: 1
diego_database_instances: 1
diego_brain_instances: 1
diego_cell_instances: 3
doppler_instances: 1
loggregator_traffic_controller_instances: 1
tcp_router_instances: 1
syslog_adapter_instances: 3

# Whether or not the ERT VMs are internet connected.
internet_connected: true
EOF

PATCHED_PIPELINE=$(
  yaml-patch \
    -o state/remote-worker-tags-opsfile.yml \
    -o state/bugfix-install-pcf-create-infrastructure-opsfile.yml \
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
exit

