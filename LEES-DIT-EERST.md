# Spiek.me-iOS-app — v1.21.1 (build 23) — CI-fix, alleen gewijzigde bestanden

Alle 6 bestanden hieronder gaan naar de GitHub-repo `Spiek.me-iOS-app`,
op exact hetzelfde pad als in deze zip (bestaande bestanden overschrijven).
Let op: `Spiek.xcodeproj/project.pbxproj` zit in de map `Spiek.xcodeproj` —
sleep die map als geheel, of open het bestand via de GitHub-editor.
Deze zip bevat niets voor de App Store en niets om te negeren.

| Bestand | Wat |
|---|---|
| `SpiekCore/Tests/SpiekCoreTests/TrustSafetyTests.swift` | DE FIX: 14× `await` uit de `XCTAssert*`-autoclosures gehesen (hierdoor faalde `swift test`) |
| `Spiek.xcodeproj/project.pbxproj` | CURRENT_PROJECT_VERSION 22 → 23, MARKETING_VERSION 1.21.0 → 1.21.1 (2 configuraties) |
| `Spiek/State/AppModel.swift` | alleen de app-string in het report-bundle: `ios/1.21.0` → `ios/1.21.1` |
| `CHANGELOG.md` | nieuw kopje 1.21.1 |
| `README.md` | titel + versieregel 1.21.1 (build 23) |
| `BUILD.md` | versieregel 1.21.1 (build 23) |

Niet in deze zip (bewust, wacht op jouw besluit): de P0.7a-CI-workflow
(`.github/workflows/test.yml` is op GitHub nog de oude).

Release-tag na upload:

    v1.21.1
