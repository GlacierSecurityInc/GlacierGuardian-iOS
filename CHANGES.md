# Glacier Guardian Changelog

## Version 7.3.2

* Group privacy hardening: new group chats are private by default, and a group is
  no longer mistakenly treated as public (which could previously allow a group
  message to be sent in plaintext)
* Updated the in-app Licenses list to match the libraries the app ships

## Version 7.3.1

* Added a network-interface policy for calls, keeping call media on the intended
  interface (WebRTC ICE)

## Version 7.3

* Added a post-login permissions primer and a Permissions section in Settings
* Prompt to sign in again when the server rejects stored credentials, with
  automatic credential refresh on authentication failures
* Faster, steadier contact list: fewer redundant roster writes and smoother
  presence, display-name, and photo updates
* Fixed a crash opening `xmpp://` deep links
* Clear cached Twilio calling registration on sign-out
* Cleaned up legacy account data on upgrade

## Version 7.2

* Group bookmarks now use the standard XEP-0402 (Bookmarks 2)
* Privacy & cache hardening: caches are purged on logout, plaintext and media are
  kept out of on-disk caches, and the minimum XMPP TLS version is raised to 1.2
* Never fall back to sending a message in the clear when OMEMO encryption fails
* More reliable calls and reconnection, including keeping incoming calls alive
  through setup
* Updated WireGuard and WebRTC

## Version 7.1

* Initial public release of Glacier Guardian

## Earlier history

Glacier Guardian evolved from Glacier Messenger (versions 1.0–2.x, 2017) and is
based on [ChatSecure-iOS](https://github.com/ChatSecure/ChatSecure-iOS).
