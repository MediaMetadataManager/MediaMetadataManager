//
//  Ratings.swift
//  Subler
//
//  Created by Damiano Galassi on 04/02/2020.
//

import Foundation

final class Ratings {
    static let shared = Ratings()
    let countries: [Country]

    private init() {
        guard let url = Bundle.main.url(forResource: "Ratings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let countries = try? JSONDecoder().decode([Country].self, from: data) else { fatalError() }

        self.countries = countries
    }

    func rating(countryCode: String, mediaKind: MediaKind, name: String) -> Rating? {
        guard let country = countries.first(where: { $0.displayName == countryCode }) else { return nil }
        return country.ratings.first(where: {$0.media.contains(mediaKind.description) && $0.displayName == name})
    }

    func rating(storeCode: Int, mediaKind: MediaKind, code: String) -> Rating? {
        guard let country = countries.first(where: { $0.storeCode == storeCode }) else { return nil }
        return country.ratings.first(where: {$0.media.contains(mediaKind.description) && $0.code == code})
    }
}

struct Country: Decodable {
    let displayName: String
    let storeCode: Int
    let ratings: [Rating]

    enum CodingKeys: String, CodingKey {
        case displayName = "country", storeCode, ratings
    }
}

struct Rating: Decodable {
    let media: String
    let prefix: String
    let code: String
    let value: String
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case media, prefix, code = "itunes-code", value = "itunes-value", displayName = "description"
    }

    var iTunesCode: String { "\(prefix)|\(code)|\(value)|" }
}

extension Ratings {
    /// Autocomplete values for a naming-rule condition's Rating field
    /// (see NamingCondition/OutputPrefsViewController), localized the same
    /// simple way Hans asked for: Germany's ratings ("Ab 18 Jahren", ...)
    /// when the system region is Germany, the USA's MPAA/TV ratings
    /// ("NC-17", "PG-13", ...) otherwise. These are exactly the display
    /// names NamingCondition.comparableRatingValue(for:rawValue:) extracts
    /// from a real, provider-tagged file's Rating metadata, so a value
    /// picked from this list is guaranteed to actually match -- unlike a
    /// hand-typed value such as "USA NC-17", which never will.
    static func conditionAutocompleteValues(mediaKind: MediaKind) -> [String] {
        let countryName = Locale.current.regionCode == "DE" ? "Deutschland" : "USA"
        guard let country = shared.countries.first(where: { $0.displayName == countryName }) else { return [] }
        return country.ratings
            .filter { $0.media == mediaKind.description }
            .map { $0.displayName }
    }
}
