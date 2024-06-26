#!/usr/bin/env bash

# This is a copy of the Trino's core/docker/build.sh with the following changes:
# * only support building a released version
# * fetch the original container resources from the Trino repository
# * after extracting the server tarball, remove all plugins and catalog configs except jmx and memory
# * test only one architecture
# * pushes the images with a manifest

set -euo pipefail
set +H

usage() {
    cat <<EOF 1>&2
Usage: $0 [-h] [-a <ARCHITECTURES>] -r <VERSION>
Builds the Trino Docker image

-h       Display help
-a       Build the specified comma-separated architectures, defaults to amd64,arm64,ppc64le
-r       Build the specified Trino release version, downloads all required artifacts
-j       Build the Trino release with specified JDK distribution
EOF
}

# Retrieve the script directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "${SCRIPT_DIR}" || exit 2

SOURCE_DIR="${SCRIPT_DIR}/trino"

ARCHITECTURES=(amd64 arm64 ppc64le)
TRINO_VERSION=

JDK_RELEASE=""
JDKS_PATH="${SOURCE_DIR}/core/jdk"

while getopts ":a:h:r:j:" o; do
    case "${o}" in
        a)
            IFS=, read -ra ARCH_ARG <<< "$OPTARG"
            for arch in "${ARCH_ARG[@]}"; do
                if echo "${ARCHITECTURES[@]}" | grep -v -w "$arch" &>/dev/null; then
                    usage
                    exit 0
                fi
            done
            ARCHITECTURES=("${ARCH_ARG[@]}")
            ;;
        r)
            TRINO_VERSION=${OPTARG}
            ;;
        h)
            usage
            exit 0
            ;;
        j)
            JDK_RELEASE="${OPTARG}"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))

function prop {
    grep "^${1}=" "${2}" | cut -d'=' -f2-
}

function check_environment() {
    if ! command -v jq &> /dev/null; then
        echo >&2 "Please install jq"
        exit 1
    fi
}

function jdk_download_link() {
  local RELEASE_PATH="${1}"
  local ARCH="${2}"

  if [ -f "${RELEASE_PATH}/${ARCH}" ]; then
    prop "distributionUrl" "${RELEASE_PATH}/${ARCH}"
  else
     echo "${ARCH} is not supported for JDK release ${RELEASE_PATH}"
     exit 1
  fi
}

check_environment

if [ -z "$TRINO_VERSION" ]; then
    echo >&2 "ERROR: Trino version is required"
    exit 2
fi

echo "🎣 Downloading server and client artifacts for release version ${TRINO_VERSION}"
for artifactId in io.trino:trino-server:"${TRINO_VERSION}":tar.gz io.trino:trino-cli:"${TRINO_VERSION}":jar:executable; do
    mvn -B -C dependency:get -Dtransitive=false -Dartifact="$artifactId"
done
local_repo=$(mvn -B help:evaluate -Dexpression=settings.localRepository -q -DforceStdout)
trino_server="$local_repo/io/trino/trino-server/${TRINO_VERSION}/trino-server-${TRINO_VERSION}.tar.gz"
trino_client="$local_repo/io/trino/trino-cli/${TRINO_VERSION}/trino-cli-${TRINO_VERSION}-executable.jar"
chmod +x "$trino_client"

rm -rf trino
(
    git clone \
        --branch "$TRINO_VERSION" \
        --depth 1 \
        --filter=blob:none \
        --no-checkout \
        https://github.com/trinodb/trino \
        "${SOURCE_DIR}"
    cd "${SOURCE_DIR}"
    git checkout "$TRINO_VERSION" -- core/docker
    git checkout "$TRINO_VERSION" -- core/jdk
)

TRINO_DIR="${SCRIPT_DIR}/trino/core/docker"

[ -n "$JDK_RELEASE" ] || JDK_RELEASE=$(cat "${SOURCE_DIR}/core/jdk/current")

echo "🧱 Preparing the image build context directory"
WORK_DIR="$(mktemp -d)"
cp "$trino_server" "${WORK_DIR}/"
cp "$trino_client" "${WORK_DIR}/"
tar -C "${WORK_DIR}" -xzf "${WORK_DIR}/trino-server-${TRINO_VERSION}.tar.gz"
rm "${WORK_DIR}/trino-server-${TRINO_VERSION}.tar.gz"
shopt -s extglob
find "${WORK_DIR}/trino-server-${TRINO_VERSION}"/plugin -type d -mindepth 1 -maxdepth 1 ! \( -name jmx -o -name memory \) -exec rm -rf {} +
cp -R "$TRINO_DIR/bin" "${WORK_DIR}/trino-server-${TRINO_VERSION}"
cp -R "$TRINO_DIR/default" "${WORK_DIR}/"
find "${WORK_DIR}"/default/etc/catalog -type f -mindepth 1 -maxdepth 1 ! \( -name jmx.properties -o -name memory.properties \) -exec rm -f {} +

TAG_PREFIX="trino:${TRINO_VERSION}"

for arch in "${ARCHITECTURES[@]}"; do
    echo "🫙  Building the image for $arch with JDK ${JDK_RELEASE}"
    docker build \
        "${WORK_DIR}" \
        --progress=plain \
        --pull \
        --build-arg JDK_VERSION="${JDK_RELEASE}" \
        --build-arg JDK_DOWNLOAD_LINK="$(jdk_download_link "${JDKS_PATH}/${JDK_RELEASE}" "${arch}")" \
        --platform "linux/$arch" \
        -f "$TRINO_DIR/Dockerfile" \
        -t "${TAG_PREFIX}-$arch" \
        --build-arg "TRINO_VERSION=${TRINO_VERSION}"
done

echo "🧹 Cleaning up the build context directory"
rm -r "${WORK_DIR}"

echo "🏃 Testing built images"
# shellcheck disable=SC1091
source "$TRINO_DIR/container-test.sh"

arch="$(dpkg --print-architecture || uname -m)"
case "$arch" in
    i386 | i686 | x86_64 | darwin-amd64) arch="amd64" ;;
    arm) arch="arm64" ;;
esac
# TODO: remove when https://github.com/multiarch/qemu-user-static/issues/128 is fixed
if [[ $arch != "ppc64le" ]]; then
    test_container "${TAG_PREFIX}-$arch" "linux/$arch"
fi
docker image inspect -f '🚀 Built {{.RepoTags}} {{.Id}}' "${TAG_PREFIX}-$arch"

echo "Pushing built images"
REPO=nineinchnick/trino-core
TARGET=$REPO:$TRINO_VERSION
for arch in "${ARCHITECTURES[@]}"; do
    docker tag "$TAG_PREFIX-$arch" "$TARGET-$arch"
    docker push "$TARGET-$arch"
done

for name in "$TARGET" "$REPO:latest"; do
    docker manifest create "$name" "${ARCHITECTURES[@]/#/$TARGET-}"
    docker manifest push --purge "$name"
done
