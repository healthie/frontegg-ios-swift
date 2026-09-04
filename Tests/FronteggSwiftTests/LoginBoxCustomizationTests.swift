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

    // MARK: - Sign-up redirect

    func testSignUpUrlAloneIsEnoughToInjectAScript() throws {
        // The redirect stands on its own: an app can own its sign-up flow
        // without overriding any theme or copy.
        let script = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: nil,
            localizations: nil,
            signUpUrl: "https://app.example.com/sign_up/select"
        ))

        XCTAssertTrue(script.contains("https://app.example.com/sign_up/select"))
        XCTAssertTrue(script.contains("[data-test-id=\"redirect-to-signup\"]"))
    }

    func testSignUpUrlIsNullWhenAbsent() throws {
        let script = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: nil,
            localizations: ["en": ["loginBox": ["login": ["title": "Sign-in"]]]]
        ))

        XCTAssertTrue(script.contains("var SIGN_UP_URL = null;"))
    }

    func testSignUpUrlIsJsonEncoded() throws {
        // A quote in the value would otherwise terminate the JS string literal.
        let script = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: nil,
            localizations: nil,
            signUpUrl: "https://app.example.com/sign_up?q=%22x%22&a=1"
        ))

        XCTAssertTrue(script.contains("var SIGN_UP_URL = \"https://app.example.com/sign_up?q=%22x%22&a=1\";"))
    }

    // MARK: - Sign-up URL validation

    func testNonHttpSchemesAreRejected() {
        // The value reaches location.assign, so a script URL must never survive.
        for url in [
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "file:///etc/passwd",
            "myapp://sign_up"
        ] {
            XCTAssertNil(
                LoginBoxCustomization.sanitizedSignUpUrl(url),
                "expected \(url) to be rejected"
            )
        }
    }

    /// A host that presents its own sign-up flow outside this WebView points
    /// `loginBoxSignUpUrl` at its own scheme; the delegate's custom-scheme
    /// branch then opens it and dismisses the box.
    func testAppRegisteredSchemesAreAccepted() {
        // The test bundle registers none, so this asserts the mechanism rather
        // than a specific scheme: whatever the bundle declares is accepted, and
        // anything else is not.
        let schemes = LoginBoxCustomization.appUrlSchemes()

        if let scheme = schemes.first {
            XCTAssertEqual(
                LoginBoxCustomization.sanitizedSignUpUrl("\(scheme)://sign-up"),
                "\(scheme)://sign-up"
            )
        }
        XCTAssertFalse(schemes.contains("definitelynotregistered"))
        XCTAssertNil(LoginBoxCustomization.sanitizedSignUpUrl("definitelynotregistered://sign-up"))
    }

    func testAppSchemeUrlNeedsNoHost() {
        // `myapp://sign-up` parses with host "sign-up", but `myapp:sign-up`
        // has none — neither should be rejected for that reason, only for not
        // being a registered scheme.
        XCTAssertNil(LoginBoxCustomization.sanitizedSignUpUrl("unregistered:sign-up"))
    }

    func testRelativeAndEmptyUrlsAreRejected() {
        XCTAssertNil(LoginBoxCustomization.sanitizedSignUpUrl("/users/sign_up/select"))
        XCTAssertNil(LoginBoxCustomization.sanitizedSignUpUrl(""))
        XCTAssertNil(LoginBoxCustomization.sanitizedSignUpUrl(nil))
        XCTAssertNil(LoginBoxCustomization.sanitizedSignUpUrl("https://"))
    }

    func testHttpAndHttpsAreAccepted() {
        XCTAssertEqual(
            LoginBoxCustomization.sanitizedSignUpUrl("https://app.example.com/x"),
            "https://app.example.com/x"
        )
        // http is allowed for local development against a plain-HTTP host.
        XCTAssertEqual(
            LoginBoxCustomization.sanitizedSignUpUrl("http://localhost:3000/x"),
            "http://localhost:3000/x"
        )
        XCTAssertEqual(
            LoginBoxCustomization.sanitizedSignUpUrl("HTTPS://app.example.com/x"),
            "HTTPS://app.example.com/x"
        )
    }

    func testRejectedUrlDoesNotProduceASignUpOnlyScript() {
        // Nothing else to apply and an unusable URL: no script at all, rather
        // than one that installs listeners which can never fire.
        XCTAssertNil(LoginBoxCustomization.script(
            themeOptions: nil,
            localizations: nil,
            signUpUrl: "javascript:alert(1)"
        ))
    }

    /// The listener code ships in every script and is gated at runtime on
    /// `SIGN_UP_URL`, so a copy-only injection carries it but never binds it.
    func testListenersAreRuntimeGatedOnTheRedirect() throws {
        let withoutRedirect = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: nil,
            localizations: ["en": ["loginBox": ["login": ["title": "Sign-in"]]]]
        ))
        XCTAssertTrue(withoutRedirect.contains("var SIGN_UP_URL = null;"))
        XCTAssertTrue(withoutRedirect.contains("if (SIGN_UP_URL) {"))

        let withRedirect = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: nil,
            localizations: nil,
            signUpUrl: "https://app.example.com/sign_up"
        ))
        XCTAssertTrue(withRedirect.contains("addEventListener('click'"))
        XCTAssertTrue(withRedirect.contains("addEventListener('keydown'"))
    }

    func testOverridesAndRedirectCoexist() throws {
        let script = try XCTUnwrap(LoginBoxCustomization.script(
            themeOptions: ["loginBox": ["palette": ["primary": ["main": "#3F6655"]]]],
            localizations: ["en": ["loginBox": ["login": ["signUpLink": "Sign up now"]]]],
            signUpUrl: "https://app.example.com/sign_up"
        ))

        XCTAssertTrue(script.contains("#3F6655"))
        XCTAssertTrue(script.contains("Sign up now"))
        XCTAssertTrue(script.contains("https://app.example.com/sign_up"))
    }
}
