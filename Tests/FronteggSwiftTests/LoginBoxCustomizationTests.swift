import XCTest
@testable import FronteggSwift

/// Covers the script builder that applies host-supplied theme/copy overrides to
/// the embedded login box.
final class LoginBoxCustomizationTests: XCTestCase {

    // MARK: - No-op cases

    func testReturnsNilWhenNothingProvided() {
        XCTAssertNil(LoginBoxCustomization.script(themeOptions: nil, localizations: nil))
    }

    func testReturnsNilWhenOverridesAreEmpty() {
        XCTAssertNil(LoginBoxCustomization.script(themeOptions: [:], localizations: [:]))
    }

    func testReturnsNilWhenValuesAreNotJSONSerializable() {
        // Date is not a valid JSON type; the builder must refuse rather than
        // emit a script that throws inside the WebView.
        XCTAssertNil(LoginBoxCustomization.script(themeOptions: ["logo": Date()], localizations: nil))
    }

    // MARK: - Payload

    func testThemeOptionsAreEmittedUnderThemeV2() throws {
        let script = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: ["loginBox": ["palette": ["primary": ["main": "#3F6655"]]]],
            localizations: nil
        ))

        XCTAssertTrue(script.contains("\"themeV2\""))
        XCTAssertTrue(script.contains("#3F6655"))
        XCTAssertFalse(script.contains("\"localizations\""))
    }

    func testLocalizationsAreEmittedUnderLocalizations() throws {
        let script = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: nil,
            localizations: ["en": ["loginBox": ["login": ["title": "Sign-in"]]]]
        ))

        XCTAssertTrue(script.contains("\"localizations\""))
        XCTAssertTrue(script.contains("Sign-in"))
        XCTAssertFalse(script.contains("\"themeV2\""))
    }

    func testBothOverridesAreEmittedTogether() throws {
        let script = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: ["loginBox": ["logo": ["image": "https://example.com/logo.png"]]],
            localizations: ["en": ["loginBox": ["login": ["continue": "Log In"]]]]
        ))

        XCTAssertTrue(script.contains("\"themeV2\""))
        XCTAssertTrue(script.contains("\"localizations\""))
        // JSONSerialization escapes forward slashes, so the URL appears as
        // `https:\/\/example.com\/logo.png`. See testLogoURLSurvivesSlashEscaping.
        XCTAssertTrue(script.contains("example.com"))
        XCTAssertTrue(script.contains("logo.png"))
        XCTAssertTrue(script.contains("Log In"))
    }

    /// JSONSerialization writes `/` as `\/`. That is valid JSON and decodes back
    /// to the original URL, so the login box still receives a usable logo source.
    func testLogoURLSurvivesSlashEscaping() throws {
        let url = "https://example.com/assets/logo.png"
        let json = try XCTUnwrap(LoginBoxCustomization.encodeOverrides(
            ["themeV2": ["loginBox": ["logo": ["image": url]]]]
        ))

        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let themeV2 = try XCTUnwrap(decoded?["themeV2"] as? [String: Any])
        let loginBox = try XCTUnwrap(themeV2["loginBox"] as? [String: Any])
        let logo = try XCTUnwrap(loginBox["logo"] as? [String: Any])

        XCTAssertEqual(logo["image"] as? String, url)
    }

    // MARK: - Script shape

    func testScriptTargetsTheLoginBoxMetadataRequest() throws {
        let script = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: ["loginBox": ["themeName": "modern"]],
            localizations: nil
        ))

        XCTAssertTrue(script.contains(LoginBoxCustomization.metadataPath))
        XCTAssertTrue(script.contains("window.fetch"))
        // Guards against double-installing when the script is injected twice.
        XCTAssertTrue(script.contains("__fronteggLoginBoxOverridesInstalled"))
        // The placeholder must always be substituted.
        XCTAssertFalse(script.contains("__FRONTEGG_OVERRIDES__"))
    }

    // MARK: - Encoding

    func testEncodingEscapesJavaScriptLineTerminators() throws {
        // U+2028/U+2029 are valid JSON but terminate a line in JavaScript source,
        // which would break the emitted script.
        let json = try XCTUnwrap(LoginBoxCustomization.encodeOverrides(
            ["localizations": ["en": ["note": "a\u{2028}b\u{2029}c"]]]
        ))

        XCTAssertFalse(json.contains("\u{2028}"))
        XCTAssertFalse(json.contains("\u{2029}"))
        XCTAssertTrue(json.contains("\\u2028"))
        XCTAssertTrue(json.contains("\\u2029"))
    }

    func testEncodedOverridesRoundTripAsJSON() throws {
        let overrides: [String: Any] = ["themeV2": ["loginBox": ["palette": ["primary": ["main": "#16284A"]]]]]
        let json = try XCTUnwrap(LoginBoxCustomization.encodeOverrides(overrides))

        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let themeV2 = try XCTUnwrap(decoded?["themeV2"] as? [String: Any])
        let loginBox = try XCTUnwrap(themeV2["loginBox"] as? [String: Any])
        let palette = try XCTUnwrap(loginBox["palette"] as? [String: Any])
        let primary = try XCTUnwrap(palette["primary"] as? [String: Any])

        XCTAssertEqual(primary["main"] as? String, "#16284A")
    }

    func testQuotesInCopyDoNotBreakTheScript() throws {
        let script = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: nil,
            localizations: ["en": ["loginBox": ["login": ["title": "Don't \"stop\" now"]]]]
        ))

        // JSONSerialization escapes the double quotes; the apostrophe is safe
        // because the payload is embedded as an object literal, not a string.
        XCTAssertTrue(script.contains("Don't \\\"stop\\\" now"))
    }

    // MARK: - Footer

    /// A footer with one usable row, for tests that only care that it is valid.
    private func footerPayload(
        url: String = "https://policies.google.com/privacy",
        hideBadge: Bool = true
    ) -> [String: Any] {
        [
            "hideCaptchaBadge": hideBadge,
            "rows": [
                ["variant": "fine", "segments": [
                    ["text": "Protected by reCAPTCHA — "],
                    ["label": "Privacy Policy", "url": url]
                ]]
            ]
        ]
    }

    func testFooterAloneIsEnoughToInjectAScript() throws {
        // The footer stands on its own: an app can add an attribution without
        // overriding any theme or copy.
        let script = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: nil,
            localizations: nil,
            footer: footerPayload()
        ))

        XCTAssertTrue(script.contains("https://policies.google.com/privacy"))
        XCTAssertTrue(script.contains("[data-test-id=\"root-element\"]"))
    }

    func testFooterIsNullWhenAbsent() throws {
        let script = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: nil,
            localizations: ["en": ["loginBox": ["login": ["title": "Sign-in"]]]]
        ))

        XCTAssertTrue(script.contains("var FOOTER = null;"))
    }

    func testBadgeIsOnlyHiddenWhenAsked() throws {
        let hiding = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: nil, localizations: nil,
            footer: footerPayload(hideBadge: true)
        ))
        XCTAssertTrue(hiding.contains("\"hideCaptchaBadge\":true"))

        let notHiding = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: nil, localizations: nil,
            footer: footerPayload(hideBadge: false)
        ))
        XCTAssertTrue(notHiding.contains("\"hideCaptchaBadge\":false"))
    }

    /// Hiding Google's badge is only permissible alongside a visible
    /// attribution, so the rule ships with the footer and nowhere else.
    func testBadgeRuleShipsOnlyWithAFooter() throws {
        let copyOnly = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: nil,
            localizations: ["en": ["loginBox": ["login": ["title": "Sign-in"]]]]
        ))
        XCTAssertTrue(copyOnly.contains("var FOOTER = null;"))
        // The helper is present but unreachable, because the script returns
        // before it when FOOTER is null.
        XCTAssertTrue(copyOnly.contains("if (!FOOTER) { return; }"))
    }

    /// Host copy must never be interpreted as markup.
    func testFooterCopyIsRenderedAsTextNotHtml() throws {
        let script = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: nil, localizations: nil, footer: footerPayload()
        ))

        XCTAssertTrue(script.contains("anchor.textContent = segment.label;"))
        XCTAssertTrue(script.contains("createTextNode(segment.text)"))
        // Asserted as an assignment rather than a bare substring, so the
        // comment in the script explaining why we avoid it doesn't trip this.
        XCTAssertFalse(script.contains(".innerHTML ="))
        XCTAssertFalse(script.contains("insertAdjacentHTML"))
    }

    /// The footer follows the login screen only, matching the React SDK where
    /// `boxFooter` is configured under `login`.
    func testFooterIsScopedToTheLoginScreen() throws {
        let script = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: nil, localizations: nil, footer: footerPayload()
        ))

        XCTAssertTrue(script.contains("[data-test-id=\"login-page-title\"]"))
    }

    func testQuotesInFooterCopyDoNotBreakTheScript() throws {
        let script = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: nil,
            localizations: nil,
            footer: [
                "rows": [["variant": "body", "segments": [["text": "Don't \"stop\""]]]]
            ]
        ))

        XCTAssertTrue(script.contains("Don't \\\"stop\\\""))
    }

    // MARK: - Footer validation

    /// A bad URL degrades the segment to plain text rather than dropping it: a
    /// legal attribution missing a fragment reads as a bug, whereas an unlinked
    /// label still says what it needs to say.
    func testUnsafeSchemesDegradeToPlainText() throws {
        for url in [
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "file:///etc/passwd",
            "definitelynotregistered://sign-up"
        ] {
            let sanitized = try XCTUnwrap(
                LoginBoxCustomization.sanitizedFooter(footerPayload(url: url)),
                "expected \(url) to still produce a footer"
            )
            let rows = try XCTUnwrap(sanitized["rows"] as? [[String: Any]])
            let segments = try XCTUnwrap(rows[0]["segments"] as? [[String: Any]])

            XCTAssertEqual(segments.count, 2, "expected \(url) to keep both segments")
            XCTAssertEqual(segments[1]["text"] as? String, "Privacy Policy")
            XCTAssertNil(segments[1]["url"], "expected \(url) to be stripped")
        }
    }

    func testHttpAndHttpsLinksAreAccepted() {
        XCTAssertEqual(
            LoginBoxCustomization.sanitizedLinkUrl("https://app.example.com/x"),
            "https://app.example.com/x"
        )
        // http is allowed for local development against a plain-HTTP host.
        XCTAssertEqual(
            LoginBoxCustomization.sanitizedLinkUrl("http://localhost:3000/x"),
            "http://localhost:3000/x"
        )
        XCTAssertEqual(
            LoginBoxCustomization.sanitizedLinkUrl("HTTPS://app.example.com/x"),
            "HTTPS://app.example.com/x"
        )
    }

    func testRelativeAndEmptyLinksAreRejected() {
        XCTAssertNil(LoginBoxCustomization.sanitizedLinkUrl("/users/sign_up/select"))
        XCTAssertNil(LoginBoxCustomization.sanitizedLinkUrl(""))
        XCTAssertNil(LoginBoxCustomization.sanitizedLinkUrl(nil))
        XCTAssertNil(LoginBoxCustomization.sanitizedLinkUrl("https://"))
    }

    /// A host that presents its own sign-up flow outside this WebView points a
    /// footer link at its own scheme; the delegate's custom-scheme branch then
    /// opens it and dismisses the box.
    func testAppRegisteredSchemesAreAccepted() {
        // The test bundle registers none, so this asserts the mechanism rather
        // than a specific scheme: whatever the bundle declares is accepted, and
        // anything else is not.
        let schemes = LoginBoxCustomization.appUrlSchemes()

        if let scheme = schemes.first {
            XCTAssertEqual(
                LoginBoxCustomization.sanitizedLinkUrl("\(scheme)://sign-up"),
                "\(scheme)://sign-up"
            )
        }
        XCTAssertFalse(schemes.contains("definitelynotregistered"))
        XCTAssertNil(LoginBoxCustomization.sanitizedLinkUrl("definitelynotregistered://sign-up"))
    }

    func testEmptyFooterProducesNothing() {
        XCTAssertNil(LoginBoxCustomization.sanitizedFooter(nil))
        XCTAssertNil(LoginBoxCustomization.sanitizedFooter([:]))
        XCTAssertNil(LoginBoxCustomization.sanitizedFooter(["rows": []]))
        // Rows with no usable segments are dropped, and a footer with no
        // surviving rows is no footer at all.
        XCTAssertNil(LoginBoxCustomization.sanitizedFooter([
            "rows": [["variant": "body", "segments": [["label": ""], ["text": ""]]]]
        ]))
    }

    func testUnknownVariantFallsBackToBody() throws {
        let sanitized = try XCTUnwrap(LoginBoxCustomization.sanitizedFooter([
            "rows": [["variant": "enormous", "segments": [["text": "hi"]]]]
        ]))
        let rows = try XCTUnwrap(sanitized["rows"] as? [[String: Any]])

        XCTAssertEqual(rows[0]["variant"] as? String, "body")
    }

    // MARK: - External link allowlist

    /// Only `http(s)` links leave for the OS. An app-scheme link is a hand-off
    /// the custom-scheme branch already owns, and must not be short-circuited
    /// into "open externally, keep the box mounted".
    func testExternalUrlsCoverOnlyHttpLinks() {
        let urls = LoginBoxCustomization.footerExternalUrls([
            "rows": [["variant": "body", "segments": [
                ["label": "Privacy", "url": "https://policies.google.com/privacy"],
                ["label": "Terms", "url": "http://example.com/terms"],
                ["label": "Sign up", "url": "myapp://sign-up"],
                ["text": "no link here"]
            ]]]
        ])

        XCTAssertEqual(urls, [
            "https://policies.google.com/privacy",
            "http://example.com/terms"
        ])
    }

    func testExternalUrlsAreEmptyWithoutAFooter() {
        XCTAssertTrue(LoginBoxCustomization.footerExternalUrls(nil).isEmpty)
        XCTAssertTrue(LoginBoxCustomization.footerExternalUrls(["rows": []]).isEmpty)
    }

    /// A rejected URL must not linger in the allowlist, or the delegate would
    /// hand the OS a value the footer never rendered.
    func testExternalUrlsExcludeRejectedLinks() {
        XCTAssertTrue(
            LoginBoxCustomization.footerExternalUrls(
                footerPayload(url: "javascript:alert(1)")
            ).isEmpty
        )
    }

    func testOverridesAndFooterCoexist() throws {
        let script = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: ["loginBox": ["palette": ["primary": ["main": "#3F6655"]]]],
            localizations: ["en": ["loginBox": ["login": ["title": "Sign-in"]]]],
            footer: footerPayload()
        ))

        XCTAssertTrue(script.contains("#3F6655"))
        XCTAssertTrue(script.contains("Sign-in"))
        XCTAssertTrue(script.contains("https://policies.google.com/privacy"))
    }
}
