# Guardian for [Glacier](http://www.glaciersecurity.com)

Guardian for [Glacier](http://www.glaciersecurity.com) is an [XMPP](https://en.wikipedia.org/wiki/XMPP) messaging client for iOS that integrates [OMEMO](https://en.wikipedia.org/wiki/OMEMO) encrypted messaging support as well as external calling and messaging.

Because Glacier services typically run within a private network, numerous assumptions were purposefully made to optimize and simplify usage for this specific scenario. Glacier is not intended for use with public XMPP servers.


## Build Instructions

You'll need [CocoaPods](http://cocoapods.org) installed for our dependencies. 
    
    $ gem install cocoapods
    
Download the source code and **don't forget** to pull down all of the submodules as well. 

    $ git clone https://github.com/GlacierSecurityInc/GlacierGuardian-iOS.git
    $ cd GlacierGuardian-iOS/
    $ git submodule update --init --recursive
    
Now you'll need to build the dependencies. 
    
    $ pod repo update
    $ pod install

Then, build in XCode.

*Note*: Because of issues in the way the WireGuardNetworkExtension (specifically libwg-go.a library) needed to be built, this code might not successfully do a general build and it will not run on Simulator. But it should build and run on a physical device without issues.

*Note*: **Open `.xcworkspace` rather than `.xcodeproj`** because we use Cocoapods!


