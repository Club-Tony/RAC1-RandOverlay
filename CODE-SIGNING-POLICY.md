# RandOverlay Code Signing Policy

This document states who may change RandOverlay's source, who may authorise a code signing
request, and what those signatures do and do not assert. It exists because signing a binary
is a claim about provenance, and that claim is only as good as the process behind it.

It is published in the project repository so that anyone verifying a signature can check the
process against it.

## Roles

RandOverlay is maintained by one person. The roles below are still named separately, because
they carry different obligations and because the project may gain contributors later.

| Role | Who | Responsibility |
|---|---|---|
| Committer | Tony (GitHub [@Club-Tony](https://github.com/Club-Tony)) | May push to the repository directly. |
| Reviewer | Tony (GitHub [@Club-Tony](https://github.com/Club-Tony)) | Reviews every contribution from anyone else before it is merged. |
| Approver | Tony (GitHub [@Club-Tony](https://github.com/Club-Tony)) | Authorises each individual signing request. |

Contact: open an issue at
<https://github.com/Club-Tony/RAC1-RandOverlay/issues>, or write to
`124948941+Club-Tony@users.noreply.github.com`.

There are no other collaborators on the repository. If that changes, this document is updated
in the same change that grants the access, and no contributor is given committer rights
without also being listed here.

Multi-factor authentication is required on the GitHub account that owns this repository and on
the SignPath account used to request signatures. Neither account may be shared.

## What gets signed

Two artifacts, both produced from this repository's own source:

1. `RandOverlay_layer.dll`, the Vulkan layer, signed before the release ZIP is assembled;
2. `RandOverlay-Setup-vX.Y.Z.exe`, the bootstrapper, signed before `SHA256SUMS.txt` is
   finalised, so the published checksums cover the signed bytes.

Nothing else is signed. In particular, this project never signs a third-party binary. The
dependencies it detects or downloads (Archipelago, RPCS3, the Ratchet and Clank apworld, the
multiplayer package, PopTracker, Lawrence) are the work of other people, are not redistributed
here, and carry whatever signature their own authors give them. Where such a project is
unsigned, the right fix is for that project to obtain its own certificate, not for RandOverlay
to vouch for it.

## How a signing request is made

Signing requests originate only from the release workflow in
`.github/workflows/release-vulkan.yml`, triggered by pushing a `vX.Y.Z` tag. The workflow
builds both binaries from the tagged commit on a clean GitHub-hosted runner, using build
dependencies pinned to exact revisions, and publishes a release manifest recording the source
commit and a SHA-256 for every file in the payload.

Every request is approved by hand by the approver named above. Approval is per request, never
standing, and is refused if the request does not correspond to a tag on this repository.

No signing key, certificate, or credential is stored in the repository or in a
general-purpose repository secret. The signing service holds the key; this project holds only
the identifiers needed to address a request to it.

## Privacy

RandOverlay collects nothing. It has no telemetry, no analytics, no crash reporting, and no
account system, and it transmits no user data to the maintainer or to any third party. The
full statement, including the small number of user-initiated network requests the setup tool
makes and exactly where they go, is in [PRIVACY.md](PRIVACY.md).

No personal data is transferred to the signing service. It receives build artifacts and the
metadata identifying the release they came from.

## Reporting a problem

If you believe a signed RandOverlay binary is not what this policy describes, or that a
signature has been misused, open an issue at
<https://github.com/Club-Tony/RAC1-RandOverlay/issues>. For anything that should not be public
first, use the contact address above.

A signature says the binary came from this repository through the process above. It is not a
warranty of fitness, and it does not mean the software has been audited.

## Attribution

Free code signing is provided by [SignPath.io](https://about.signpath.io/), with a certificate
issued by the [SignPath Foundation](https://signpath.org/).
