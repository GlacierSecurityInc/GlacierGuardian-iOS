# Submodule patches

Changes that belong to a submodule's own history but were prepared from the superproject.
Apply inside the submodule, commit there, then bump the submodule pointer here.

## XMPPFramework-xmppuri-range-safety.patch

Fixes GUA 03 (Sept 2026 assessment): `XMPPURI.parseURIString:` computed an authority range
against `NSNotFound` whenever an `xmpp://` URI had no `/` after the authority, so
`substringWithRange:` raised `NSInvalidArgumentException`. Since the URI arrived on the main
thread from a tapped link, the app was terminated (`EXC_CRASH` / `SIGABRT`).

Guardian no longer registers the `xmpp` scheme, so this is defense in depth for anything that
reaches `XMPPURI` another way.

Prepared against submodule commit `30dc648e2c6525474f7f551c30d0d60c9156af6e`.

```bash
cd Submodules/XMPPFramework && git apply ../Patches/XMPPFramework-xmppuri-range-safety.patch
```

Behaviour is unchanged for every input that did not already throw; see
`GlacierTests/XMPPURIParsingTests.m` for the cases that back that up.
