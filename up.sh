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
OPSMAN_VERSION=2.0.2
SRT_VERSION=2.0.1
DEVSTACK_ENV=~stack/devstack/openrc
DEVSTACK_USER=admin
DEVSTACK_PROJECT=demo

set -x

mkdir -p bin
PATH=$PATH:$(pwd)/bin

if ! [ -f bin/pivnet ]; then
  curl -L "https://github.com/pivotal-cf/pivnet-cli/releases/download/v0.0.49/pivnet-linux-amd64-0.0.49" > bin/pivnet
  chmod +x bin/pivnet
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

source $DEVSTACK_ENV $DEVSTACK_USER $DEVSTACK_PROJECT
openstack create image bin/pcf-openstack.raw opsman/$OPSMAN_VERSION
openstack create \
  --image=opsman/$OPSMAN_VERSION \
  m1.xlarge \
  --security-group=bosh \
  --key-name=bosh \
  opsman \
  ;
