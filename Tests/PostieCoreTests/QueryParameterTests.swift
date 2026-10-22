import Foundation
import XCTest
@testable import PostieCore

final class QueryParameterTests: XCTestCase {
    func testParsePreservesOrderedDuplicatesAndFragment() {
        let parsed = QueryParameters.parse(
            displayURL: "https://example.test/path?tag=one&tag=two&flag&empty=#section?literal")

        XCTAssertEqual(parsed.baseURL, "https://example.test/path#section?literal")
        XCTAssertEqual(parsed.fields.map(\.name), ["tag", "tag", "flag", "empty"])
        XCTAssertEqual(parsed.fields.map(\.value), ["one", "two", "", ""])
        XCTAssertEqual(parsed.fields.map { $0.queryEncoding?.hasEquals }, [true, true, false, true])
        XCTAssertEqual(
            QueryParameters.render(baseURL: parsed.baseURL, fields: parsed.fields),
            "https://example.test/path?tag=one&tag=two&flag&empty=#section?literal")
    }

    func testRawPercentEncodingPlusAndUnicodeRoundTripUnchanged() {
        let source = "https://example.test/p%2f?q=a+b%2fc%2B&encoded=%7e&unicode=é%20雪#frag%2f"
        let parsed = QueryParameters.parse(displayURL: source)

        XCTAssertEqual(parsed.fields.map(\.value), ["a+b/c+", "~", "é 雪"])
        XCTAssertEqual(QueryParameters.render(baseURL: parsed.baseURL, fields: parsed.fields), source)
    }

    func testEditingOneComponentPreservesOtherRawComponent() {
        var parsed = QueryParameters.parse(displayURL: "https://example.test?%71=a%2fb")
        parsed.fields[0].value = "new+value/%"

        XCTAssertEqual(
            QueryParameters.render(baseURL: parsed.baseURL, fields: parsed.fields),
            "https://example.test?%71=new%2Bvalue%2F%25")

        parsed.fields[0].value = "a/b"
        parsed.fields[0].name = "new key"
        XCTAssertEqual(
            QueryParameters.render(baseURL: parsed.baseURL, fields: parsed.fields),
            "https://example.test?new%20key=a%2fb")
    }

    func testTableFieldsUseStrictEncodingAndRemainOrdered() {
        let fields = [
            HTTPField(),
            HTTPField(name: "a+b", value: "a b&c=d/?#%"),
            HTTPField(name: "ignored", value: "x", isEnabled: false),
            HTTPField(name: "a+b", value: "é雪"),
            HTTPField(name: "", value: "meaningful"),
        ]

        XCTAssertEqual(
            QueryParameters.render(baseURL: "https://example.test#fragment", fields: fields),
            "https://example.test?a%2Bb=a%20b%26c%3Dd%2F%3F%23%25&a%2Bb=%C3%A9%E9%9B%AA&=meaningful#fragment")
    }

    func testBareKeyBecomesEqualsWhenValueIsAdded() {
        var parsed = QueryParameters.parse(displayURL: "https://example.test?flag")
        parsed.fields[0].name = "renamed"
        XCTAssertEqual(QueryParameters.encodedQuery(fields: parsed.fields), "renamed")

        parsed.fields[0].value = "yes"
        XCTAssertEqual(QueryParameters.encodedQuery(fields: parsed.fields), "renamed=yes")
    }

    func testExplicitEmptyQueryAndComponentsArePreserved() {
        for suffix in ["?", "?=", "?&&", "?a=1&&=v&"] {
            let source = "https://example.test/path" + suffix + "#fragment"
            let parsed = QueryParameters.parse(displayURL: source)
            XCTAssertEqual(QueryParameters.render(baseURL: parsed.baseURL, fields: parsed.fields), source)
        }

        XCTAssertNil(QueryParameters.encodedQuery(fields: [HTTPField()]))
        XCTAssertEqual(QueryParameters.encodedQuery(fields: QueryParameters.parse(displayURL: "?").fields), "")
    }

    func testClearedPreviouslyNonemptyRowBecomesInactive() {
        var parsed = QueryParameters.parse(displayURL: "https://example.test?a=1")
        parsed.fields[0].name = ""
        parsed.fields[0].value = ""

        XCTAssertEqual(QueryParameters.render(baseURL: parsed.baseURL, fields: parsed.fields), "https://example.test")
    }

    func testTemplateDelimitersDoNotSplitURLOrComponents() {
        let source = "https://{{host?/#}}/path?{{key&=}}={{value?&#=}}&next={{other}}#{{fragment?#}}"
        let parsed = QueryParameters.parse(displayURL: source)

        XCTAssertEqual(parsed.baseURL, "https://{{host?/#}}/path#{{fragment?#}}")
        XCTAssertEqual(parsed.fields.map(\.name), ["{{key&=}}", "next"])
        XCTAssertEqual(parsed.fields.map(\.value), ["{{value?&#=}}", "{{other}}"])
        XCTAssertEqual(QueryParameters.render(baseURL: parsed.baseURL, fields: parsed.fields), source)
    }

    func testTableTemplatesStayLiteralUntilPreparation() {
        let fields = [HTTPField(name: "{{name}}", value: "before {{value?&#}} after")]

        XCTAssertEqual(QueryParameters.encodedQuery(fields: fields), "{{name}}=before%20{{value?&#}}%20after")
        XCTAssertEqual(
            QueryParameters.encodedQuery(fields: fields, preserveTemplates: false),
            "%7B%7Bname%7D%7D=before%20%7B%7Bvalue%3F%26%23%7D%7D%20after")
    }

    func testPartialAndMalformedURLsRoundTripWithoutValidationOrRewriting() {
        for source in [
            "", "h", "https://", "https://{{unfinished?query#fragment", "https://example.test?x=%&y=%ZZ&z=%FF",
            "https://example.test?x={{unfinished&#", "?x=space value#fragment",
        ] {
            let parsed = QueryParameters.parse(displayURL: source)
            XCTAssertEqual(QueryParameters.render(baseURL: parsed.baseURL, fields: parsed.fields), source)
        }
    }

    func testMalformedPercentEncodingRemainsEditableAndIsSafeForPreparation() {
        let parsed = QueryParameters.parse(displayURL: "https://example.test?bad=%ZZ&utf8=%FF&space=a b&unicode=雪")

        XCTAssertEqual(parsed.fields.map(\.value), ["%ZZ", "%FF", "a b", "雪"])
        XCTAssertEqual(
            QueryParameters.encodedQuery(fields: parsed.fields, preserveTemplates: false),
            "bad=%25ZZ&utf8=%FF&space=a%20b&unicode=%E9%9B%AA")
    }

    func testPreparationPreservesValidRawComponentsAndEncodesSubstitutedValues() {
        var parsed = QueryParameters.parse(displayURL: "https://example.test?%71=a%2fb+%2B&token={{value}}&equals=a=b")
        parsed.fields[1].value = "resolved /+&"

        XCTAssertEqual(
            QueryParameters.encodedQuery(fields: parsed.fields, preserveTemplates: false),
            "%71=a%2fb+%2B&token=resolved%20%2F%2B%26&equals=a=b")
    }

    func testURLEditPreservesIDsAndDisabledRows() {
        let previous = QueryParameters.parse(displayURL: "https://example.test?tag=one&tag=two&last=3")
        let disabled = HTTPField(name: "saved", value: "keep", isEnabled: false)
        var fields = previous.fields
        fields.insert(disabled, at: 1)
        let edited = QueryParameters.parse(
            displayURL: "https://example.test/new?tag=one&tag=changed&last=3", previousFields: fields,
            previousBase: previous.baseURL)

        XCTAssertEqual(edited.baseURL, "https://example.test/new")
        XCTAssertEqual(edited.fields.map(\.id), fields.map(\.id))
        XCTAssertEqual(edited.fields[1], disabled)
        XCTAssertEqual(edited.fields[2].value, "changed")
    }

    func testURLEditMatchesSurvivingRowsBeforeAssigningNewIDs() {
        let previous = QueryParameters.parse(displayURL: "https://example.test?a=1&a=2&b=3")
        let edited = QueryParameters.parse(
            displayURL: "https://example.test?new=0&a=2&b=3", previousFields: previous.fields)

        XCTAssertEqual(edited.fields[1].id, previous.fields[1].id)
        XCTAssertEqual(edited.fields[2].id, previous.fields[2].id)
        XCTAssertEqual(Set(edited.fields.map(\.id)).count, 3)
    }

    func testRemovingQueryRetainsDisabledRows() {
        let disabled = HTTPField(name: "saved", value: "keep", isEnabled: false)
        let parsed = QueryParameters.parse(
            displayURL: "https://example.test#fragment",
            previousFields: [HTTPField(name: "gone", value: "1"), disabled])

        XCTAssertEqual(parsed.fields, [disabled])
        XCTAssertEqual(parsed.baseURL, "https://example.test#fragment")
    }

    func testUnchangedDisplayRetainsExistingRowsExactly() {
        let fields = [
            HTTPField(name: "name", value: "value"), HTTPField(),
            HTTPField(name: "disabled", value: "x", isEnabled: false),
        ]
        let parsed = QueryParameters.parse(
            displayURL: "https://example.test?name=value", previousFields: fields, previousBase: "https://example.test")

        XCTAssertEqual(parsed.fields, fields)
    }

    func testLegacyNormalizationAppendsTableRowsOnceAndPreservesTheirIDs() {
        let fields = [HTTPField(name: "tag", value: "table"), HTTPField(name: "saved", value: "x", isEnabled: false)]
        let normalized = QueryParameters.normalize(url: "https://example.test?tag=url#fragment", fields: fields)

        XCTAssertEqual(normalized.baseURL, "https://example.test#fragment")
        XCTAssertEqual(normalized.fields.map(\.value), ["url", "table", "x"])
        XCTAssertEqual(Array(normalized.fields.suffix(2)), fields)
        XCTAssertEqual(
            QueryParameters.render(baseURL: normalized.baseURL, fields: normalized.fields),
            "https://example.test?tag=url&tag=table#fragment")
        XCTAssertEqual(QueryParameters.normalize(url: normalized.baseURL, fields: normalized.fields), normalized)
    }

    func testOldHTTPFieldJSONDecodesWithoutMetadata() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"key\",\"value\":\"value\",\"isEnabled\":false}".utf8)
        let field = try JSONDecoder().decode(HTTPField.self, from: data)

        XCTAssertEqual(field, HTTPField(id: id, name: "key", value: "value", isEnabled: false))
        XCTAssertNil(field.queryEncoding)
    }

    func testQueryMetadataRoundTripsThroughCodable() throws {
        let parsed = QueryParameters.parse(displayURL: "https://example.test?%71=a%2fb&flag&=")
        let encoded = try JSONEncoder().encode(parsed.fields)
        let decoded = try JSONDecoder().decode([HTTPField].self, from: encoded)

        XCTAssertEqual(decoded, parsed.fields)
        XCTAssertEqual(
            QueryParameters.render(baseURL: parsed.baseURL, fields: decoded), "https://example.test?%71=a%2fb&flag&=")
    }
}
