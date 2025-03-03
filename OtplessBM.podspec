Pod::Spec.new do |s|
  s.name             = 'OtplessBM'
  s.version          = '1.0.1'
  s.summary          = 'Standalone SDK for Otpless Headless functionality.'

  s.description      = <<-DESC
  'OtplessBM is a modern iOS SDK built with Swift that provides Otpless' Headless capabilities. Get your user authentication sorted in just five minutes by integrating of Otpless sdk.'
  DESC

  s.homepage         = 'https://github.com/otpless-tech/otpless-headless-iOS-sdk'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Otpless' => 'sparsh.chadha@otpless.com' }
  s.source           = { :git => 'https://github.com/otpless-tech/otpless-headless-iOS-sdk.git', :tag => s.version.to_s }
  s.social_media_url = 'https://twitter.com/otpless'
  s.ios.deployment_target = '13.0'
  
  s.subspec 'Core' do |core|
    core.source_files = 'Sources/OtplessBM/**/*'
  end
  
  s.subspec 'FacebookSupport' do |fb|
    fb.ios.deployment_target = '13.0'
    fb.dependency 'OtplessBM/Core'
    fb.source_files = 'Sources/OtplessBM/sdkLogin/FacebookSupport/**/*'
    fb.dependency 'FBSDKCoreKit', '~> 17.0.2'
    fb.dependency 'FBSDKLoginKit', '~> 17.0.2'
  end

  s.subspec 'GoogleSupport' do |google|
    google.ios.deployment_target = '13.0'
    google.dependency 'OtplessBM/Core'
    google.source_files = 'Sources/OtplessBM/sdkLogin/GoogleSupport/**/*'
    google.dependency 'GoogleSignIn', '~> 8.1.0-vwg-eap-1.0.0'
    google.dependency 'GoogleSignInSwiftSupport', '~> 8.0.0'
  end
  
  s.resource_bundles = {
    'OtplessBM' => ['Sources/PrivacyInfo.xcprivacy']
  }
  
  s.swift_versions = ['5.5', '5.6', '5.7', '5.8', '5.9, '6.0']

end
