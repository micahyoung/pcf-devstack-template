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
    --release-version=2.0.2 \
    --glob='*pcf-openstack-*.raw' \
    --download-dir=bin/ \
    --accept-eula \
  ;
  mv bin/pcf-openstack-*.raw bin/pcf-openstack.raw
fi
