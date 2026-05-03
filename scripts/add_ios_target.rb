#!/usr/bin/env ruby
# One-shot setup that adds an iOS app target alongside the existing macOS target.
#
# Strategy: every Swift source file gets membership in BOTH targets. Mac-only
# files use `#if os(macOS)` fences. SPM packages KeyboardShortcuts and
# LaunchAtLogin are macOS-only and intentionally skipped for the iOS target.
#
# Run from repo root: `ruby scripts/add_ios_target.rb`. Idempotent: re-running
# detects an existing CentmondiOS target and exits.

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../Centmond.xcodeproj', __dir__)
IOS_TARGET   = 'CentmondiOS'
IOS_BUNDLE   = 'mani.Centmond.iOS'
IOS_DEPLOY   = '26.0'

# Packages explicitly mac-only — do not link to iOS target.
MAC_ONLY_PACKAGES = ['KeyboardShortcuts', 'LaunchAtLogin'].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)
mac = project.targets.find { |t| t.name == 'Centmond' } or abort 'macOS target Centmond not found'

if project.targets.any? { |t| t.name == IOS_TARGET }
  puts "==> #{IOS_TARGET} target already exists; nothing to do."
  exit 0
end

puts "==> Creating iOS target #{IOS_TARGET}"
ios = project.new_target(:application, IOS_TARGET, :ios, IOS_DEPLOY, nil, :swift)

# --- Build settings ---------------------------------------------------------
ios.build_configurations.each do |config|
  config.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER'                          => IOS_BUNDLE,
    'PRODUCT_NAME'                                       => 'Centmond',
    'MARKETING_VERSION'                                  => '1.0',
    'CURRENT_PROJECT_VERSION'                            => '1',
    'SWIFT_VERSION'                                      => '5.0',
    'IPHONEOS_DEPLOYMENT_TARGET'                         => IOS_DEPLOY,
    'TARGETED_DEVICE_FAMILY'                             => '1,2',
    'GENERATE_INFOPLIST_FILE'                            => 'YES',
    'INFOPLIST_KEY_CFBundleDisplayName'                  => 'Centmond',
    'INFOPLIST_KEY_UILaunchScreen_Generation'            => 'YES',
    'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone' => 'UIInterfaceOrientationPortrait',
    'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad'   => 'UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight',
    'INFOPLIST_KEY_NSCameraUsageDescription'             => 'Centmond uses the camera to scan receipts.',
    'INFOPLIST_KEY_NSPhotoLibraryUsageDescription'       => 'Centmond saves receipt photos to your library when you choose to.',
    'INFOPLIST_KEY_NSFaceIDUsageDescription'             => 'Centmond uses Face ID to unlock the app.',
    'CODE_SIGN_STYLE'                                    => 'Automatic',
    'ASSETCATALOG_COMPILER_APPICON_NAME'                 => 'AppIcon',
    'ENABLE_PREVIEWS'                                    => 'YES',
    'SWIFT_EMIT_LOC_STRINGS'                             => 'YES'
  )
  # Don't auto-pick a dev team; user can set it in the UI when they're ready
  # to run on a device. The simulator builds without one.
  config.build_settings.delete('DEVELOPMENT_TEAM')
end

# --- Source + resource discovery via Xcode 16 synchronized groups ---------
# This project uses `PBXFileSystemSynchronizedRootGroup` instead of explicit
# build-file entries. Both targets reference the same `Centmond/` synchronized
# group, and Xcode auto-discovers Swift files / Assets / etc. at build time.
puts '==> Sharing fileSystemSynchronizedGroups with macOS target'
mac.file_system_synchronized_groups.each do |g|
  ios.file_system_synchronized_groups << g unless ios.file_system_synchronized_groups.include?(g)
  puts "    + #{g.path}"
end

# --- SPM dependencies: link cross-platform packages, skip mac-only ----------
mac_pkg_deps = mac.package_product_dependencies
puts "==> Linking SPM products (skipping #{MAC_ONLY_PACKAGES.join(', ')})"
mac_pkg_deps.each do |dep|
  product = dep.product_name
  pkg = dep.package
  pkg_name = pkg.respond_to?(:name) ? pkg.name : nil
  pkg_repo = pkg.respond_to?(:repositoryURL) ? pkg.repositoryURL : ''
  if MAC_ONLY_PACKAGES.any? { |m| product.include?(m) || pkg_repo.to_s.include?(m) }
    puts "    - skip #{product}"
    next
  end
  new_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  new_dep.product_name = product
  new_dep.package = pkg
  ios.package_product_dependencies << new_dep

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = new_dep
  ios.frameworks_build_phase.files << build_file
  puts "    + #{product}"
end

project.save

puts "==> Done. New target: #{IOS_TARGET} (bundle #{IOS_BUNDLE}, iOS #{IOS_DEPLOY})"
puts "    Next: build with"
puts "    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \\"
puts "      -scheme #{IOS_TARGET} -destination 'generic/platform=iOS Simulator' build"
