require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name         = 'rn-cashify-ota-update'
  s.module_name  = 'CashifyOtaUpdate'
  s.version      = package['version']
  s.summary      = package['description']
  s.homepage     = 'https://github.com/vipin-cashify/rn-cashify-ota-update'
  s.license      = { :type => 'UNLICENSED' }
  s.authors      = { 'Cashify' => 'engineering@cashify.in' }
  s.platforms    = { :ios => '15.0' }
  s.source       = { :git => 'https://github.com/vipin-cashify/rn-cashify-ota-update.git', :tag => "v#{s.version}" }

  s.source_files  = 'ios/**/*.{h,m,mm,swift}'
  s.requires_arc  = true
  s.swift_version = '5.0'

  # Host Swift can `import CashifyOtaUpdate`.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }

  # Host must pin the Firebase iOS SDK (via @react-native-firebase or an explicit
  # $FirebaseSDKVersion) — this dep is deliberately unversioned so it follows
  # the host's pin instead of fighting it.
  s.dependency 'FirebaseRemoteConfig'
  s.dependency 'GzipSwift', '~> 5.1.1'

  if respond_to?(:install_modules_dependencies, true)
    # RN >= 0.71: wires React-Core, folly flags, New Arch defines.
    install_modules_dependencies(s)
  else
    s.dependency 'React-Core'
  end
end
