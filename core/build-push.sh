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
EOF
}

ARCHITECTURES=(amd64 arm64 ppc64le)
TRINO_VERSION=

while getopts ":a:h:r:" o; do
    case "${o}" in
        a)
            IFS=, read -ra ARCHITECTURES <<<"$OPTARG"
            ;;
        r)
            TRINO_VERSION=${OPTARG}
            ;;
        h)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))

if [ -z "$TRINO_VERSION" ]; then
    echo >&2 "ERROR: Trino version is required"
    exit 2
fi

function temurin_jdk_link() {
  JDK_VERSION="${1}"
  ARCH="${2}"

  versionsUrl="https://api.adoptium.net/v3/info/release_names?heap_size=normal&image_type=jdk&lts=true&os=linux&page=0&page_size=20&project=jdk&release_type=ga&semver=false&sort_method=DEFAULT&sort_order=ASC&vendor=eclipse&version=%28${JDK_VERSION}%2C%5D"
  if ! result=$(curl -fLs "$versionsUrl" -H 'accept: application/json'); then
    echo >&2 "Failed to fetch release names for JDK version [${JDK_VERSION}, ) from Temurin API : $result"
    exit 1
  fi

  if ! RELEASE_NAME=$(echo "$result" | jq -er '.releases[]' | grep "${JDK_VERSION}" | head -n 1); then
    echo >&2 "Failed to determine release name: ${RELEASE_NAME}"
    exit 1
  fi

  case "${ARCH}" in
    arm64)
      echo "https://api.adoptium.net/v3/binary/version/${RELEASE_NAME}/linux/aarch64/jdk/hotspot/normal/eclipse?project=jdk"
    ;;
    amd64)
      echo "https://api.adoptium.net/v3/binary/version/${RELEASE_NAME}/linux/x64/jdk/hotspot/normal/eclipse?project=jdk"
    ;;
    ppc64le)
      echo "https://api.adoptium.net/v3/binary/version/${RELEASE_NAME}/linux/ppc64le/jdk/hotspot/normal/eclipse?project=jdk"
    ;;
  *)
    echo "${ARCH} is not supported for Docker image"
    exit 1
    ;;
  esac
}

# Retrieve the script directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "${SCRIPT_DIR}" || exit 2

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
        ;
    cd trino
    git checkout "$TRINO_VERSION" -- core/docker
    git checkout "$TRINO_VERSION" -- .java-version
)
TRINO_DIR=trino/core/docker

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
JDK_VERSION=$(cat trino/.java-version)

for arch in "${ARCHITECTURES[@]}"; do
    echo "🫙  Building the image for $arch with JDK ${JDK_VERSION}"
    docker build \
        "${WORK_DIR}" \
        --progress=plain \
        --pull \
        --build-arg JDK_VERSION="${JDK_VERSION}" \
        --build-arg JDK_DOWNLOAD_LINK="$(temurin_jdk_link "${JDK_VERSION}" "${arch}")" \
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
