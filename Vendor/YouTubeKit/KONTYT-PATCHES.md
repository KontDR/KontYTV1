# Vendored dependency provenance
Upstream: https://github.com/alexeichhorn/YouTubeKit
Revision: 7f75a2299dc329c0b7855afb25d47663a02855cb
License: MIT (LICENSE preserved).

KontYT modifications to YouTube.swift:
- Removed age-verification query hints from watch URL.
- LOGIN_REQUIRED always throws.
- Removed age-gate fallback and its function.
- Remote extraction branch always throws; app also explicitly selects methods: [.local].

No success guarantee; player changes can break local extraction. Review upstream license and security changes when updating. Sources and upstream tests are vendored; there is no package fetch to third-party servers during application extraction. The app still communicates directly with YouTube/Google media hosts.
