#!/usr/bin/env bash
set -euo pipefail

DIR=/var/tmp/aos-core-v6.1.2
BASE=https://github.com/aosedge/meta-aos-vm/releases/download/v6.1.2
mkdir -p "$DIR"
cd "$DIR"

fetch() {
    local name="$1"
    echo "FETCHING ${name}"
    curl -fL --retry 10 --retry-all-errors --retry-delay 2 -C - -o "$name" "${BASE}/${name}"
    echo "OK ${name}"
}

fetch aos-vm-fota-main-qemux86-64-6.1.2.tar.gz
fetch aos-vm-fota-secondary-qemux86-64-6.1.2.tar.gz
fetch aos-vm-image-qemux86-64-6.1.2.tar.xz
ls -lh
echo DOWNLOAD_OK
