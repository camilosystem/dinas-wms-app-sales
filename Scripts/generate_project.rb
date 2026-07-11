#!/usr/bin/env ruby
# frozen_string_literal: true

# Genera DinasSales.xcodeproj (target de app iOS universal + target de tests) sobre
# el código en DinasSales/. GRDB se integra como paquete SPM remoto.
#
# Reproducible: borra y regenera el .xcodeproj. Fuente de verdad del proyecto Xcode.
#
#   ruby Scripts/generate_project.rb
#
# Requiere la gema `xcodeproj` (gem install --user-install xcodeproj).

require 'xcodeproj'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(ROOT, 'DinasSales.xcodeproj')
DEPLOYMENT_TARGET = '16.0'
BUNDLE_ID = 'com.dinas.sales'
GRDB_URL = 'https://github.com/groue/GRDB.swift.git'
GRDB_MIN_VERSION = '6.29.0'

# --- Proyecto -----------------------------------------------------------------

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)

# Grupos que apuntan a las carpetas reales.
app_group = project.new_group('DinasSales', 'DinasSales')
tests_group = project.new_group('DinasSalesTests', 'DinasSalesTests')

# --- Paquete SPM: GRDB --------------------------------------------------------

pkg_ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
pkg_ref.repositoryURL = GRDB_URL
pkg_ref.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => GRDB_MIN_VERSION }
project.root_object.package_references << pkg_ref

grdb_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
grdb_dep.package = pkg_ref
grdb_dep.product_name = 'GRDB'

# --- Target de app ------------------------------------------------------------

app = project.new_target(:application, 'DinasSales', :ios, DEPLOYMENT_TARGET)

# Fuentes .swift bajo DinasSales/ (excepto recursos).
Dir.glob(File.join(ROOT, 'DinasSales', '**', '*.swift')).sort.each do |path|
  ref = app_group.new_file(path)
  app.add_file_references([ref])
end

# Info.plist (no versionado dentro del grupo de compilación, solo referencia).
app_group.new_file(File.join(ROOT, 'DinasSales', 'Resources', 'Info.plist'))

# GRDB como dependencia del target de app.
app.package_product_dependencies << grdb_dep
grdb_build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
grdb_build_file.product_ref = grdb_dep
app.frameworks_build_phase.files << grdb_build_file

app.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = BUNDLE_ID
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['MARKETING_VERSION'] = '0.1.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['INFOPLIST_FILE'] = 'DinasSales/Resources/Info.plist'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  s['TARGETED_DEVICE_FAMILY'] = '1,2'          # iPhone + iPad (universal)
  s['SWIFT_VERSION'] = '5.0'
  s['DEVELOPMENT_LANGUAGE'] = 'es'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['ENABLE_PREVIEWS'] = 'YES'
  s['MIDDLEWARE_BASE_URL'] = ''                # configurar por entorno (ver AppConfig)
end

# --- Target de tests ----------------------------------------------------------

tests = project.new_target(:unit_test_bundle, 'DinasSalesTests', :ios, DEPLOYMENT_TARGET)
Dir.glob(File.join(ROOT, 'DinasSalesTests', '**', '*.swift')).sort.each do |path|
  ref = tests_group.new_file(path)
  tests.add_file_references([ref])
end
tests.add_dependency(app)
tests.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = "#{BUNDLE_ID}.tests"
  s['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  s['SWIFT_VERSION'] = '5.0'
  s['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/DinasSales.app/DinasSales'
  s['BUNDLE_LOADER'] = '$(TEST_HOST)'
end

# --- Esquema ------------------------------------------------------------------

project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.add_test_target(tests)
scheme.save_as(PROJECT_PATH, 'DinasSales', true)

puts "Generado #{PROJECT_PATH}"
