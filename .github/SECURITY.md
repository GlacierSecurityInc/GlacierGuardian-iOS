# Security Policy

Glacier Security builds tooling for teams handling sensitive communications, and
we take reports about this client seriously. Thank you for taking the time to
report an issue responsibly.

## Reporting a vulnerability

**Please report security problems privately — do not post them publicly.** This
repository has GitHub Issues disabled; the channels below are how to reach us.

Report it one of two ways:

1. **GitHub private vulnerability reporting** — use the **Report a vulnerability**
   button under this repository's **Security** tab. This keeps the report private
   until a fix ships and gives us a place to discuss it with you.
2. **Email** — [support@glacier.chat](mailto:support@glacier.chat) with `SECURITY`
   in the subject line.

If you do not get an acknowledgement within a few business days, please follow up
by the other channel rather than assuming the report was received — mail does get
filtered.

### What to include

The more of this you can provide, the faster we can confirm and fix:

- The affected version (**Settings → About**, or `CFBundleShortVersionString` in a build)
- Device model and iOS version
- What an attacker can achieve, and what access they need to start
- Reproduction steps, or a proof of concept
- Relevant logs or stack traces, with your own identifiers and message content
  removed

### What to expect

We aim to acknowledge reports promptly, confirm or dispute the finding after
triage, and keep you updated while we work on a fix. We will tell you when a fix
ships and, unless you would rather stay anonymous, credit you in the release
notes. If we decide not to act on a report, we will explain why.

Please give us a reasonable opportunity to ship a fix before disclosing publicly.

## Supported versions

Fixes land on the current release line. Older lines are not backported.

| Version | Supported |
| --- | --- |
| 7.3.x | Yes |
| 7.2.x and earlier | No |

The app targets iOS 15 and later.

## Scope

**In scope** — anything in this repository that affects the confidentiality,
integrity, or availability of user communications or credentials. For example:

- Flaws in message encryption, key handling, or trust decisions (OMEMO)
- Authentication, session, or token handling problems
- Leakage of message content, credentials, or keys through logs, backups,
  exported files, the keychain, or shared App Group containers
- URL schemes, universal links, the pasteboard, or app extensions (share,
  notification, WireGuard tunnel) that another app on the device can abuse
- Certificate validation, pinning, or transport security weaknesses

**Out of scope** — reports we are unlikely to act on:

- Findings that require a jailbroken or already-compromised device, or physical
  access to an unlocked device
- Automated scanner output with no demonstrated impact
- Vulnerabilities in third-party dependencies with no exploitable path in this
  app — please report those upstream
- Missing hardening that has no concrete attack behind it
- Social engineering, and anything targeting Glacier Security staff or
  infrastructure rather than this client

Server-side and account infrastructure is not in this repository. Send those
reports to [support@glacier.chat](mailto:support@glacier.chat) as well, and note
that they concern infrastructure rather than the app.

## A note on upstream code

This application began as a fork of
[ChatSecure](https://github.com/ChatSecure/ChatSecure-iOS) and still carries a
substantial amount of its XMPP and OMEMO code, along with the underlying
Signal/OMEMO libraries. If you find a vulnerability that also exists in unmodified
upstream ChatSecure (or those libraries), please report it to the relevant project
as well — their users are affected too. If you are unsure whether a finding is ours
or upstream's, report it to us and we will work that out and coordinate.

## Please do not

While researching, avoid anything that harms real users:

- Accessing, modifying, or exfiltrating accounts or data that are not yours
- Degrading service for other users
- Testing against Glacier Security production infrastructure without written
  permission — test against your own build and your own accounts

Research conducted in good faith under this policy is welcome, and we will not
pursue action over it.
