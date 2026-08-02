// SPDX-License-Identifier: GPL-2.0-or-later
// Every language must ship exactly the LocalizedKey set with matching format
// specifiers; this is what keeps "add a lproj file" safe without codegen.

import Foundation
import Testing
@testable import ReRNDISApp

private let resourcesURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/ReRNDISApp/Resources")

private func stringsTables() throws -> [String: [String: String]] {
    let lprojs = try FileManager.default.contentsOfDirectory(atPath: resourcesURL.path)
        .filter { $0.hasSuffix(".lproj") }
    var tables: [String: [String: String]] = [:]
    for lproj in lprojs {
        let file = resourcesURL.appendingPathComponent(lproj).appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: file)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        tables[lproj] = try #require(parsed as? [String: String])
    }
    return tables
}

private func specifierCount(_ value: String) -> Int {
    value.components(separatedBy: "%@").count - 1
}

@Suite struct LocalizationTests {
    @Test func everyLanguageShipsTheExactKeySet() throws {
        let expected = Set(LocalizedKey.allCases.map(\.rawValue))
        let tables = try stringsTables()
        #expect(tables.count >= 4)
        for (lproj, table) in tables {
            #expect(Set(table.keys) == expected, "key set mismatch in \(lproj)")
        }
    }

    @Test func formatSpecifiersMatchEnglish() throws {
        let tables = try stringsTables()
        let english = try #require(tables["en.lproj"])
        for (lproj, table) in tables where lproj != "en.lproj" {
            for (key, value) in table {
                #expect(
                    specifierCount(value) == specifierCount(english[key] ?? ""),
                    "%@ count mismatch for \(key) in \(lproj)"
                )
            }
        }
    }

    @Test func noValueUsesForbiddenDashes() throws {
        for (lproj, table) in try stringsTables() {
            for (key, value) in table {
                #expect(!value.contains("\u{2014}") && !value.contains("\u{2013}"),
                        "em/en dash in \(lproj)/\(key)")
            }
        }
    }
}
