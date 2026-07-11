#!/usr/bin/env bash
# Archiva y exporta el .ipa de la App de Vendedores para distribución interna (JAMF).
#
#   Scripts/archive_export.sh [Release|Staging]
#
# Requisitos previos (una vez):
#   - Team ID en Config/Base.xcconfig (DEVELOPMENT_TEAM) y en Config/ExportOptions.plist (teamID).
#   - Certificado de distribución (Apple Distribution) instalado en el llavero.
#   - Perfil de aprovisionamiento in-house para com.dinas.sales, y su nombre en ExportOptions.plist.
#
# El build de dispositivo REQUIERE firma; sin certificado/perfil válidos, xcodebuild falla.
set -euo pipefail

CONFIG="${1:-Release}"
BUILD_DIR="build"
ARCHIVE="${BUILD_DIR}/DinasSales-${CONFIG}.xcarchive"
IPA_DIR="${BUILD_DIR}/ipa-${CONFIG}"

echo "==> Archivando (${CONFIG})"
xcodebuild archive \
	-project DinasSales.xcodeproj \
	-scheme DinasSales \
	-configuration "${CONFIG}" \
	-destination 'generic/platform=iOS' \
	-archivePath "${ARCHIVE}" \
	CODE_SIGN_STYLE=Manual

echo "==> Exportando .ipa"
xcodebuild -exportArchive \
	-archivePath "${ARCHIVE}" \
	-exportOptionsPlist Config/ExportOptions.plist \
	-exportPath "${IPA_DIR}"

echo "==> Listo: ${IPA_DIR}/DinasSales.ipa"
