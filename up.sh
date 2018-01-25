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
OPSMAN_PRODUCT_NAME=ops-manager
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

export OS_PROJECT_NAME=$OPENSTACK_PROJECT
export OS_USERNAME=$OPENSTACK_USERNAME
export OS_PASSWORD=$OPENSTACK_PASSWORD
export OS_AUTH_URL=http://$OPENSTACK_HOST/v2.0
set -x

mkdir -p bin
PATH=$PATH:$(pwd)/bin

if ! [ -f bin/pivnet ]; then
  curl -L "https://github.com/pivotal-cf/pivnet-cli/releases/download/v0.0.49/pivnet-linux-amd64-0.0.49" > bin/pivnet
  chmod +x bin/pivnet
fi

bin/pivnet login --api-token=$PIVNET_API_TOKEN

if ! [ -f bin/om ]; then
  curl -L "https://github.com/pivotal-cf/om/releases/download/0.29.0/om-linux" > bin/om
  chmod +x bin/om
fi

if ! [ -f bin/yaml-patch ]; then
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
EOF

fly --target c login --concourse-url $CONCOURSE_URL

fly --target c set-pipeline \
  --pipeline install-pcf \
  --config <(yaml-patch -o state/remote-worker-tags-opsfile.yml < bin/pcf-pipelines/install-pcf/openstack/pipeline.yml) \
  --load-vars-from state/params.yml \
  --non-interactive \
  ;

fly --target c unpause-pipeline --pipeline install-pcf
exit

