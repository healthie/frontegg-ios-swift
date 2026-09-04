//
//  LoginBoxCustomization.swift
//
//  Lets a host app theme and re-word the embedded login box at runtime.
//

import Foundation

/// Builds the document-start script that applies app-supplied `themeV2` and
/// `localizations` overrides to the embedded login box.
///
/// The hosted login box resolves its own appearance by `fetch`ing
/// `/frontegg/metadata?entityName=adminBox` and reading `rows[0].configuration`.
/// Rather than styling the rendered DOM — whose class names are generated and
/// change between login-box releases — this script wraps `window.fetch`,
/// waits for that specific response, and deep-merges the app's values into the
/// configuration before the box parses it. Every other request passes through
/// untouched, and any failure falls back to the original response.
///
/// This keeps customization on Frontegg's own documented configuration shape,
/// so it survives login-box upgrades.
///
/// `signUpUrl` is the one exception, and deliberately so. The box's own
/// `signUpUrl` is an internal route matched against `location.pathname`, and
/// the box is served from the Frontegg auth origin — so no value in the
/// configuration shape can send the user to a host application's own sign-up
/// page. That link is therefore redirected in the DOM instead, keyed on the
/// box's `data-test-id`. A test id is part of the box's test contract rather
/// than its generated styling, which is what makes this narrow exception
/// tolerable where CSS/class-name styling would not be.
enum LoginBoxCustomization {

    /// Returns `nil` when there is nothing to apply, so callers can skip
    /// injecting a script entirely.
    static func script(
        themeOptions: [String: Any]?,
        localizations: [String: Any]?,
        signUpUrl: String? = nil
    ) -> String? {
        var overrides: [String: Any] = [:]

        if let themeOptions, !themeOptions.isEmpty {
            overrides["themeV2"] = themeOptions
        }
        if let localizations, !localizations.isEmpty {
            overrides["localizations"] = localizations
        }

        let redirectUrl = sanitizedSignUpUrl(signUpUrl)

        // Either concern alone is worth injecting for, so this is not gated on
        // `overrides` being non-empty.
        guard !overrides.isEmpty || redirectUrl != nil else {
            return nil
        }

        let overridesJson = overrides.isEmpty ? "{}" : encodeOverrides(overrides)
        guard let overridesJson else { return nil }

        return template
            .replacingOccurrences(of: "__FRONTEGG_OVERRIDES__", with: overridesJson)
            .replacingOccurrences(
                of: "__FRONTEGG_SIGN_UP_URL__",
                with: redirectUrl.flatMap(encodeJsonString) ?? "null"
            )
    }

    /// Accepts only absolute `http(s)` URLs.
    ///
    /// The value reaches `location.assign`, so anything else — `javascript:`
    /// above all — is dropped rather than injected. A host app is trusted, but
    /// this value can originate in remote configuration on its side, and the
    /// cost of the check is nothing.
    static func sanitizedSignUpUrl(_ signUpUrl: String?) -> String? {
        guard let signUpUrl, !signUpUrl.isEmpty,
              let components = URLComponents(string: signUpUrl),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return nil
        }
        return signUpUrl
    }

    /// JSON-encodes a single string, including its surrounding quotes.
    static func encodeJsonString(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: [value],
            options: []
        ),
              let array = String(data: data, encoding: .utf8) else {
            return nil
        }
        // `["…"]` → `"…"`, so the caller can drop it straight into a source
        // string without re-deriving JavaScript string escaping by hand.
        return String(array.dropFirst().dropLast())
            // JSONSerialization writes `/` as `\/`. Harmless — a JS string
            // literal reads `\/` as `/` — but it makes the emitted URL hard to
            // read in a script dump, and `/` needs no escaping in either JSON
            // or JavaScript.
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// JSON-encodes the overrides for embedding in a JavaScript source string.
    static func encodeOverrides(_ overrides: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(overrides),
              let data = try? JSONSerialization.data(withJSONObject: overrides, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }

        // U+2028 and U+2029 are valid inside JSON but terminate a line in
        // JavaScript source, which would break the script we embed them in.
        return json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// Substring identifying the login box's own metadata request.
    static let metadataPath = "/frontegg/metadata?entityName=adminBox"

    private static let template = """
    (function () {
      if (window.__fronteggLoginBoxOverridesInstalled) { return; }
      var originalFetch = window.fetch;
      if (typeof originalFetch !== 'function') { return; }
      window.__fronteggLoginBoxOverridesInstalled = true;

      var overrides = __FRONTEGG_OVERRIDES__;
      var SIGN_UP_URL = __FRONTEGG_SIGN_UP_URL__;
      var METADATA_PATH = '/frontegg/metadata?entityName=adminBox';
      var SIGN_UP_SELECTOR = '[data-test-id="redirect-to-signup"]';

      // The box renders its sign-up link as
      // `<… data-test-id="redirect-to-signup" onClick=goToSignup>`, inside a
      // `[data-test-id="sign-up-message"]` container. Both ids are part of the
      // box's test contract, unlike its generated class names.
      //
      // The listener sits on `document` in the capture phase because the box
      // lives in an open shadow root: `click` and `keydown` are composed, so
      // they propagate across the boundary, and `composedPath()` still exposes
      // the real target. Capture also means we run before the box's own
      // handler, which is what lets us stop its internal navigation.
      function isSignUpTrigger(event) {
        if (!SIGN_UP_URL) { return false; }
        var path = typeof event.composedPath === 'function' ? event.composedPath() : [];
        for (var i = 0; i < path.length; i++) {
          var node = path[i];
          if (!node || node.nodeType !== 1) { continue; }
          if (typeof node.matches === 'function' && node.matches(SIGN_UP_SELECTOR)) { return true; }
          if (typeof node.closest === 'function' && node.closest(SIGN_UP_SELECTOR)) { return true; }
        }
        return false;
      }

      function redirectToSignUp(event) {
        if (!isSignUpTrigger(event)) { return; }
        event.preventDefault();
        event.stopPropagation();
        if (typeof event.stopImmediatePropagation === 'function') {
          event.stopImmediatePropagation();
        }
        window.location.assign(SIGN_UP_URL);
      }

      if (SIGN_UP_URL) {
        document.addEventListener('click', redirectToSignUp, true);
        // The link is a focusable non-button with its own onKeyDown, so keyboard
        // and switch-control users reach it this way rather than by click.
        document.addEventListener('keydown', function (event) {
          if (event.key === 'Enter' || event.key === ' ' || event.key === 'Spacebar') {
            redirectToSignUp(event);
          }
        }, true);
      }

      function isPlainObject(value) {
        return value !== null && typeof value === 'object' && !Array.isArray(value);
      }

      // Host values win on conflict; nested objects merge rather than replace so
      // untouched keys keep whatever the environment already configured.
      function deepMerge(target, source) {
        Object.keys(source).forEach(function (key) {
          var incoming = source[key];
          if (isPlainObject(incoming) && isPlainObject(target[key])) {
            deepMerge(target[key], incoming);
          } else {
            target[key] = incoming;
          }
        });
        return target;
      }

      function requestUrl(input) {
        if (typeof input === 'string') { return input; }
        if (input && typeof input.url === 'string') { return input.url; }
        if (input && typeof input.href === 'string') { return input.href; }
        return '';
      }

      window.fetch = function (input, init) {
        var pending = originalFetch.apply(this, arguments);
        if (requestUrl(input).indexOf(METADATA_PATH) === -1) { return pending; }

        return pending.then(function (response) {
          if (!response || !response.ok) { return response; }

          return response.clone().json().then(function (body) {
            var configuration =
              body && body.rows && body.rows[0] && body.rows[0].configuration;
            if (!isPlainObject(configuration)) { return response; }

            deepMerge(configuration, overrides);

            return new Response(JSON.stringify(body), {
              status: response.status,
              statusText: response.statusText,
              headers: { 'Content-Type': 'application/json' }
            });
          }).catch(function () {
            // Malformed or already-consumed body: leave the box on the
            // environment's own configuration rather than failing the request.
            return response;
          });
        });
      };
    })();
    """
}
