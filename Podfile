# Disable CocoaPods deterministic UUIDs as Pods are not checked in
ENV["COCOAPODS_DISABLE_DETERMINISTIC_UUIDS"] = "true"

# Disable Bitcode for all targets http://stackoverflow.com/a/32685434/805882
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['ENABLE_BITCODE'] = 'NO'
      config.build_settings['CLANG_WARN_DOCUMENTATION_COMMENTS'] = 'NO'
      config.build_settings['CLANG_WARN_STRICT_PROTOTYPES'] = 'NO'
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      
      if target.name == 'GlacierNotifications'
        config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= ['$(inherited)', 'TARGET_IS_EXTENSION=1']
      end
      
      if target.name == "GlacierShare"
        config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= ['$(inherited)', 'TARGET_IS_EXTENSION=1']
      end
    end
    
    if target.name == 'GiphyUISDK'
      target.build_configurations.each do |config|
        config.build_settings['DEBUG_INFORMATION_FORMAT'] = 'DWARF'
      end
    end
  end
end

platform :ios, "15.0"

use_frameworks!
# inhibit_all_warnings!

source 'https://github.com/CocoaPods/Specs.git'

abstract_target 'GlacierPods' do
  
  # Network
  pod 'CocoaAsyncSocket', '~> 7.6.3'
  pod 'GCDWebServer', '~> 3.4.2'
  pod 'XMPPFramework/Swift', :path => 'Submodules/XMPPFramework/XMPPFramework.podspec'

  # Storage
  # Catalyst patch won't be merged upstream
  pod 'SQLCipher', '~> 4.10.0'

  # The upstream 1.3.2 has a regression https://github.com/ChatSecure/ChatSecure-iOS/issues/1075
  pod 'libsqlfs/SQLCipher', :path => 'Submodules/libsqlfs/libsqlfs.podspec'

  pod 'IOCipher/GCDWebServer', :path => 'Submodules/IOCipher/IOCipher.podspec'
  
  # GRDB with SQLCipher 4
  pod 'GRDB.swift/SQLCipher'

  # Crypto
  pod 'SignalProtocolObjC', :path => 'Submodules/SignalProtocol-ObjC/SignalProtocolObjC.podspec'
  # libsodium sealed box for the encrypted push-metadata envelope (app + NSE)
  pod 'Sodium', '~> 0.9.1'

  # User Interface
  pod 'Agrume', :git => 'https://github.com/afriedmanGlacier/Agrume.git', :commit => '933d7663f3ece9041b2e39a464ccc9e04cba149a'
  pod 'SwiftyGif', '~> 5.4.5'
  pod 'Kingfisher', '~> 7.12.0'
  
  pod 'Giphy', '~> 2.2.12'
  pod 'Floaty', '~> 4.2.0'
  
  pod 'BButton', :git => 'https://github.com/jessesquires/BButton.git', :commit => 'b3d96ad996d9b71a82329c0ca724cad62564f977'
  pod 'ARChromeActivity', '~> 1.0.6'
  pod 'ParkedTextField', :git => 'https://github.com/gmertk/ParkedTextField.git'

  pod 'Font-Awesome-Swift', :git => 'https://github.com/afriedmanGlacier/Font-Awesome-Swift.git'
  pod 'TwilioVoice', '~> 6.12.0'
  pod 'IOSSecuritySuite', '1.9.11' # pinned to the last BSD-2-Clause release; 2.x is under a proprietary EULA
  #pod 'TwilioConversationsClient', '~> 4.0.3'
  pod 'DifferenceKit'

  # Debugging
  #pod 'LumberjackConsole', :path => 'Submodules/LumberjackConsole/LumberjackConsole.podspec'

  pod 'SAMKeychain', :git => 'https://github.com/afriedmanGlacier/SAMKeychain.git'
  
  # Utility
  #pod 'CocoaLumberjack/Swift', '~> 3.4.2'
  pod 'MWFeedParser', '~> 1.0'
  pod 'BBlock', '~> 1.2.1'

  pod 'Alamofire', '~> 5.9.1'

  pod 'Mantle'
  pod 'MBProgressHUD', '~> 1.2'
  pod 'TTTAttributedLabel', '~> 2.0'
  pod 'PureLayout', '~> 3.0'
  pod 'KVOController', '~> 1.2'
  pod 'XLForm', '~> 4.1'

  target 'Glacier'

  # Unit tests are hosted by the Glacier app and use `@testable import Glacier`, so they
  # need the same pod set on their search/link paths (notably Sodium and GRDB).
  target 'GlacierTests'
end

target 'GlacierNotifications' do

  pod 'SQLCipher', '~> 4.10.0'
  
  # GRDB with SQLCipher 4
  pod 'GRDB.swift/SQLCipher'
  
  pod 'SAMKeychain', :git => 'https://github.com/afriedmanGlacier/SAMKeychain.git'
  pod 'XMPPFramework/Swift', :path => 'Submodules/XMPPFramework/XMPPFramework.podspec'
  pod 'BBlock', '~> 1.2.1'
  pod 'KVOController', '~> 1.2'
  #pod 'CocoaLumberjack/Swift', '~> 3.4.2'
  
  #pod 'TwilioConversationsClient', '~> 4.0.3'
  pod 'DifferenceKit'

  # Crypto
  pod 'SignalProtocolObjC', :path => 'Submodules/SignalProtocol-ObjC/SignalProtocolObjC.podspec'
  # libsodium sealed box for opening the encrypted push-metadata envelope in the NSE
  pod 'Sodium', '~> 0.9.1'

  pod 'Mantle'
end
