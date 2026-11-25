#!/usr/bin/env bash
set -euo pipefail

SWIFTLINT_VERSION="0.65.1"
SWIFTLINT_SHA256="c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"
SWIFTLINT_URL="https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip"
INSTALL_DIR="${1:-${HOME}/.local/bin}"

if [[ -x "${INSTALL_DIR}/swiftlint" ]]; then
  CURRENT_VERSION="$("${INSTALL_DIR}/swiftlint" version || true)"
  if [[ "${CURRENT_VERSION}" == "${SWIFTLINT_VERSION}" ]]; then
    echo "SwiftLint ${SWIFTLINT_VERSION} is already installed at ${INSTALL_DIR}/swiftlint"
    exit 0
  fi
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ARCHIVE_PATH="${TMP_DIR}/portable_swiftlint.zip"
echo "Downloading SwiftLint ${SWIFTLINT_VERSION}..."
curl -fsSL "${SWIFTLINT_URL}" -o "${ARCHIVE_PATH}"

echo "${SWIFTLINT_SHA256}  ${ARCHIVE_PATH}" | shasum -a 256 -c -

unzip -q "${ARCHIVE_PATH}" -d "${TMP_DIR}/extract"
mkdir -p "${INSTALL_DIR}"
install -m 0755 "${TMP_DIR}/extract/swiftlint" "${INSTALL_DIR}/swiftlint"

INSTALLED_VERSION="$("${INSTALL_DIR}/swiftlint" version)"
if [[ "${INSTALLED_VERSION}" != "${SWIFTLINT_VERSION}" ]]; then
  echo "Expected SwiftLint ${SWIFTLINT_VERSION}, got ${INSTALLED_VERSION}" >&2
  exit 1
fi

echo "Installed SwiftLint ${INSTALLED_VERSION} to ${INSTALL_DIR}/swiftlint"
