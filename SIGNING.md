# RandOverlay Release Signing

RandOverlay release signing is intentionally service-backed. A self-signed certificate is
useful only for local testing and must not be described as public trust.

## Preferred route: SignPath Foundation

The repository is prepared for a SignPath Foundation application:

- MIT licensed;
- public source and release documentation;
- deterministic release ZIP with source commit and per-file hashes;
- no telemetry and an explicit privacy/network statement;
- release payload built from repository source plus pinned ImGui and MinHook revisions.

After the first public release, apply at <https://signpath.org/>. When accepted, add the
service-provided organization/project identifiers to GitHub repository secrets and insert
the SignPath submission/approval job before GitHub Release publication. Sign both:

1. `RandOverlay_layer.dll` before the ZIP is assembled;
2. `RandOverlay-Setup-vX.Y.Z.exe` before `SHA256SUMS.txt` is finalized.

Do not guess or commit placeholder service identifiers.

## Fallback: Microsoft Artifact Signing

Microsoft Artifact Signing is the paid fallback for an eligible individual developer.
Use its GitHub Actions integration with workload identity federation; do not store an
exportable signing private key in the repository or a general-purpose GitHub secret.

## Unsigned bootstrap releases

Until trusted signing is configured, the ZIP is the primary artifact and the EXE is
optional. Release notes and `README-INSTALL.txt` must state that Windows may show Unknown
Publisher or SmartScreen warnings and direct users to the official release URL and
`SHA256SUMS.txt`. Both artifacts remain unsigned; the warning is not called a guaranteed
false positive.
