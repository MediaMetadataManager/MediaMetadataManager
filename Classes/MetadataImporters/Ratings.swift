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
    /// Autocomplete values for a naming/delivery-rule condition's Rating
    /// field, following the General tab's "Show ratings for:" setting the
    /// same way the editor's rating menu does: every country when it says
    /// "All countries", otherwise the chosen country plus the USA. Only
    /// ratings that apply to this media kind are listed (a "Movie & TV"
    /// rating counts for both).
    ///
    /// The value offered is each rating's iTunes code, because that is what
    /// a condition is compared against: a tagged file stores its Rating as
    /// "prefix|code|value|" and NamingCondition compares the middle part.
    /// A value picked from this list is therefore guaranteed to match a
    /// file tagged with that rating, unlike a hand-typed value such as
    /// "USA NC-17". Duplicates across countries (for example "Unrated") are
    /// listed once.
    static func conditionAutocompleteValues(mediaKind: MediaKind) -> [String] {
        let selected = Prefs.ratingsCountry
        var countries: [Country] = []
        if selected == "All countries" {
            countries = shared.countries
        } else {
            if let chosen = shared.countries.first(where: { $0.displayName == selected }) { countries.append(chosen) }
            if selected != "USA", let usa = shared.countries.first(where: { $0.displayName == "USA" }) { countries.append(usa) }
        }

        var seen = Set<String>()
        var values: [String] = []
        for country in countries {
            for rating in country.ratings where rating.media.contains(mediaKind.description) {
                let code = rating.code.trimmingCharacters(in: .whitespacesAndNewlines)
                guard code.isEmpty == false, code != "???", seen.insert(code.lowercased()).inserted else { continue }
                values.append(code)
            }
        }
        return values
    }
}
