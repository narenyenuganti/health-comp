# HealthComp

An iPhone app for private, seven-day Activity competitions between two people.
Built with SwiftUI, HealthKit, and Supabase.

In development. Not yet released.

Raw HealthKit data stays on-device; competition scores are calculated locally
and synced between participants.

## Development

With Xcode and XcodeGen installed:

```sh
xcodegen generate
open HealthComp.xcodeproj
```

- [Environment setup](docs/runbooks/supabase-environments.md)
- [Tests and CI](.github/workflows)
- [Operational runbooks](docs/runbooks)
- [Release checklist](docs/release/production-beta-checklist.md)
