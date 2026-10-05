import SwiftUI
import SirDataCMP

extension KotlinInt {
    var swiftInt: Int { intValue }
    var swiftInt32: Int32 { Int32(intValue) }
}

/// Lightweight top bar used by the Purposes and Vendors screens: a back
/// chevron, an inline title, and an optional trailing accessory. Themed via
/// the resolved CMP theme. Mirrors the Material3 `TopAppBar` usage on Android.
struct CmpTopBar<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    let onBack: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.cmpResolvedTheme) private var theme

    init(title: String, subtitle: String? = nil, onBack: @escaping () -> Void,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.onBack = onBack
        self.trailing = trailing
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(theme.title)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(theme.title)
                        .lineLimit(1)
                        // FRONT-1435 — le titre de l'ecran de detail est un TITRE, comme
                        // les quatre ecrans qui portaient deja `.isHeader`. Pose ici, donc
                        // en UN exemplaire pour l'ecran activites et l'ecran partenaires.
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(theme.text.opacity(0.6))
                    }
                }
                Spacer()
                trailing()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
        }
        .background(theme.background)
    }
}

extension String {
    /// Processes locale text by first evaluating conditional tags, then
    /// stripping remaining HTML-like markup and collapsing whitespace.
    ///
    /// Conditional tags have the form:
    ///   `<tagname:id1,id2,...>inner text</tagname:id1,id2,...>`
    /// where tagname is one of: `sirdataPurposes`, `sirdataPurpose`,
    /// `purpose`, `specialFeature`.
    ///
    /// Boolean-gated tags have NO id list:
    ///   `<legitimateInterest>inner</legitimateInterest>`
    ///   `<customPurposes>inner</customPurposes>`
    ///   `<utiq>inner</utiq>`
    ///
    /// If ANY of the referenced IDs exist in the corresponding available set
    /// (or the boolean flag is true), the inner text is kept (tags removed).
    /// Otherwise the entire block (tags + inner text) is removed.
    /// After conditional processing, all remaining HTML-like tags are
    /// stripped and whitespace is collapsed.
    func processConditionalTags(
        purposeIds: Set<Int> = [],
        sirdataPurposeIds: Set<Int> = [],
        specialFeatureIds: Set<Int> = [],
        hasLegitimateInterest: Bool = false,
        hasCustomPurposes: Bool = false,
        hasUtiq: Bool = false,
        sirdataStackIds: Set<Int> = []
    ) -> String {
        var result = self

        // Process conditional tag pairs, including boolean-gated ones.
        // Group 1 = tagname, Group 2 = optional id list, Group 3 = inner text.
        // Uses non-greedy .*? instead of a backreference-inside-lookahead
        // pattern because NSRegularExpression (ICU) does not support \1 inside
        // (?!/?\1). The while-loop processes innermost tags first, correctly
        // handling nested conditional tags.
        let tagPattern = "<(sirdataPurposes|sirdataPurpose|purpose|specialFeature|legitimateInterest|customPurposes|utiq|sirdataStack)(?::([^>]+))?>(.*?)</\\1(?::[^>]*)?>"
        if let regex = try? NSRegularExpression(pattern: tagPattern, options: [.dotMatchesLineSeparators]) {
            var changed = true
            while changed {
                changed = false
                let range = NSRange(result.startIndex..., in: result)
                let matches = regex.matches(in: result, options: [], range: range)
                for match in matches {
                    guard let tagRange = Range(match.range(at: 1), in: result),
                          let innerRange = Range(match.range(at: 3), in: result),
                          let fullRange = Range(match.range, in: result) else { continue }

                    let tagName = String(result[tagRange])
                    let idsRange = Range(match.range(at: 2), in: result)
                    let ids: [Int] = idsRange.flatMap { r in
                        result[r].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    } ?? []
                    let innerText = String(result[innerRange])

                    let replacement: String
                    switch tagName {
                    case "sirdataPurposes", "sirdataPurpose":
                        // No specific IDs → keep always; with IDs → keep if any match
                        replacement = ids.isEmpty || ids.contains(where: { sirdataPurposeIds.contains($0) }) ? innerText : ""
                    case "purpose":
                        replacement = ids.contains(where: { purposeIds.contains($0) }) ? innerText : ""
                    case "specialFeature":
                        replacement = ids.contains(where: { specialFeatureIds.contains($0) }) ? innerText : ""
                    case "legitimateInterest":
                        replacement = hasLegitimateInterest ? innerText : ""
                    case "customPurposes":
                        replacement = hasCustomPurposes ? innerText : ""
                    case "utiq":
                        replacement = hasUtiq ? innerText : ""
                    case "sirdataStack":
                        replacement = ids.contains(where: { sirdataStackIds.contains($0) }) ? innerText : ""
                    default:
                        replacement = ""
                    }
                    result.replaceSubrange(fullRange, with: replacement)
                    changed = true
                    break // restart after modification
                }
            }
        }

        // Strip remaining HTML-like tags EXCEPT:
        // - self-closing tags (e.g. <mode/>, <actors/>) → resolved by buildText()
        // - classname tags (e.g. <vendors>, <purposes>) → resolved by processClassnameTags()
        // - conditional tags (legitimateInterest, customPurposes) → should be
        //   processed by the while-loop above; exclusion is a safety net against
        //   edge cases where NSRegularExpression may not match them.
        // Mirrors Kotlin Utils.processConditionalTags() parity.
        return result
            .replacingOccurrences(of: "<(?!/?(?:vendors|purposes|hostnames|websites|utiq|legitimateInterest|customPurposes|sirdataStack)\\b)[^>]*(?<!/)>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Applies the full placeholder pipeline to a purpose/stack/vendor description.
    /// Mirrors the banner text pipeline: processConditionalTags → buildText →
    /// processConditionalTags → processClassnameTags.
    ///
    /// Purpose descriptions from the GVL/Sirdata list may contain conditional
    /// tags (<purpose:1>...</purpose:1>), self-closing tags (<scope/>,
    /// <dataController/>), and classname tags (<vendors>...</vendors>) that
    /// must be resolved before display — otherwise raw tags appear as text.
    func processDescriptionPipeline(
        localize: Localize,
        partnerCount: Int,
        scopeKey: String,
        maxAgeDays: Int,
        isApplyWorkflow: Bool,
        noConsentButton: String,
        closeButton: Bool,
        hasCustomPurposes: Bool,
        customPurposeNames: [String],
        hasGeolocation: Bool,
        dataController: String = "",
        cookieDurationSeconds: Int = 0,
        purposeIds: Set<Int> = [],
        sirdataPurposeIds: Set<Int> = [],
        specialFeatureIds: Set<Int> = [],
        hasLegitimateInterest: Bool = false,
        hasCustomPurposesFlag: Bool = false,
        hasUtiq: Bool = false,
        sirdataStackIds: Set<Int> = [],
        setChoicesStyle: ThemeSetChoicesStyle = .button
    ) -> String {
        return self
            .processConditionalTags(
                purposeIds: purposeIds,
                sirdataPurposeIds: sirdataPurposeIds,
                specialFeatureIds: specialFeatureIds,
                hasLegitimateInterest: hasLegitimateInterest,
                hasCustomPurposes: hasCustomPurposesFlag,
                hasUtiq: hasUtiq,
                sirdataStackIds: sirdataStackIds
            )
            .buildText(
                localize: localize,
                partnerCount: partnerCount,
                scopeKey: scopeKey,
                maxAgeDays: maxAgeDays,
                isApplyWorkflow: isApplyWorkflow,
                noConsentButton: noConsentButton,
                closeButton: closeButton,
                hasCustomPurposes: hasCustomPurposes,
                customPurposeNames: customPurposeNames,
                hasGeolocation: hasGeolocation,
                dataController: dataController,
                cookieDurationSeconds: cookieDurationSeconds
            )
            .processConditionalTags(
                purposeIds: purposeIds,
                sirdataPurposeIds: sirdataPurposeIds,
                specialFeatureIds: specialFeatureIds,
                hasLegitimateInterest: hasLegitimateInterest,
                hasCustomPurposes: hasCustomPurposesFlag,
                hasUtiq: hasUtiq,
                sirdataStackIds: sirdataStackIds
            )
            .processClassnameTags(setChoicesStyle: setChoicesStyle)
    }

    /// Strips simple HTML-like markup (`<br/>`, `<scope/>`, `<a href=...>`, ...)
    /// from locale texts designed for the web CMP, collapsing whitespace.
    /// Mirrors Android's `String.stripMarkup`.
    var strippedMarkup: String {
        processConditionalTags()
    }

    /// Plain-text rendering of simple HTML, for the pre-iOS-15 path where
    /// `AttributedString` — and therefore `htmlToAttributedString` — is
    /// unavailable. Block tags become line breaks, everything else is dropped.
    ///
    /// `strippedMarkup` cannot stand in here: its strip regex ends with
    /// `(?<!/)>` so that `buildText()` can still resolve self-closing
    /// placeholders (`<scope/>`, `<maxAge/>`) downstream, which means it keeps
    /// `<br/>` VERBATIM — and it collapses newlines into spaces. Texts written
    /// for the web that reach a `Text` directly (`hostnames.description`) need
    /// the opposite: their `<br/>` are real line breaks.
    var htmlToPlainText: String {
        // The `(?=[\s/>])` lookahead pins the end of the tag NAME: without it
        // `p` would also swallow `<purpose:1>` and `<purposes>`, which are
        // conditional/classname tags and not line breaks at all.
        replacingOccurrences(
            of: "</?(?:br|p|div|ul|ol|li)(?=[\\s/>])[^>]*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        .replacingOccurrences(of: " ?\n ?", with: "\n", options: .regularExpression)
        // Two line breaks max in a row, like the HTML block model.
        .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts simple HTML content to an `AttributedString` (bold, italic,
    /// links, line breaks, lists) for CMP texts — mirroring the web CMP's
    /// `dangerouslySetInnerHTML` and Android's
    /// `Html.fromHtml(..., FROM_HTML_MODE_LEGACY)`.
    ///
    /// Deliberately NOT `NSAttributedString(documentType: .html)`: that
    /// importer is WebKit-backed, costs 50-300 ms per call on device (µs on
    /// the simulator) and SPINS A NESTED RUNLOOP on the main thread. Called
    /// from a SwiftUI `body`, the nested runloop lets CoreAnimation commit a
    /// PARTIAL transaction — on device this rendered a stack's expanded
    /// content while its chevron only rotated on the NEXT tap, and made every
    /// re-render of expanded rows visibly lag ("one tap behind"). The lite
    /// parser below is a few µs, allocation-only, and never yields.
    @available(iOS 15, *)
    var htmlToAttributedString: AttributedString? {
        CmpLiteHtml.parse(self)
    }

    /// Minimal HTML-to-AttributedString parser for the tag subset CMP texts
    /// actually use: `b/strong`, `i/em`, `a href`, `br`, `p`, `div`,
    /// `ul/ol/li` (bullets), plus the five XML entities, `&nbsp;` and numeric
    /// character references. Unknown tags are stripped, malformed markup is
    /// tolerated, inter-tag whitespace is collapsed like HTML. Styling uses
    /// presentation intents so bold/italic render RELATIVE to the `Text`'s
    /// font (the WebKit importer instead embedded absolute Times New Roman).
    @available(iOS 15, *)
    private enum CmpLiteHtml {
        private struct Style {
            var bold = false
            var italic = false
            var href: String? = nil
        }

        static func parse(_ html: String) -> AttributedString {
            var out = AttributedString()
            var stack = [Style()]
            var pendingSpace = false
            var atLineStart = true

            func emit(_ text: String) {
                guard !text.isEmpty else { return }
                var run = AttributedString(text)
                let s = stack[stack.count - 1]
                if s.bold && s.italic {
                    run.inlinePresentationIntent = [.stronglyEmphasized, .emphasized]
                } else if s.bold {
                    run.inlinePresentationIntent = .stronglyEmphasized
                } else if s.italic {
                    run.inlinePresentationIntent = .emphasized
                }
                if let href = s.href, let url = URL(string: href) {
                    run.link = url
                }
                out.append(run)
            }

            /// Appends up to `count` newlines, never leading and never more
            /// than 2 in a row (HTML block/paragraph semantics).
            func newline(_ count: Int = 1) {
                pendingSpace = false
                atLineStart = true
                guard !out.runs.isEmpty else { return }
                let trailing = out.characters.reversed().prefix(while: { $0 == "\n" }).count
                // Swift.min/max: unqualified, these resolve to String's
                // Sequence min()/max() because this type is nested in an
                // extension of String.
                let toAdd = Swift.min(count, Swift.max(0, 2 - trailing))
                if toAdd > 0 {
                    out.append(AttributedString(String(repeating: "\n", count: toAdd)))
                }
            }

            func text(_ raw: Substring) {
                var buffer = ""
                for ch in decodeEntities(String(raw)) {
                    if ch == " " || ch == "\n" || ch == "\t" || ch == "\r" {
                        pendingSpace = true
                    } else {
                        if pendingSpace && !atLineStart { buffer.append(" ") }
                        pendingSpace = false
                        atLineStart = false
                        buffer.append(ch)
                    }
                }
                emit(buffer)
            }

            func handleTag(_ inner: Substring) {
                var tag = inner.trimmingCharacters(in: .whitespaces)
                let isClosing = tag.hasPrefix("/")
                if isClosing { tag.removeFirst() }
                let name = tag.prefix(while: { $0.isLetter || $0.isNumber }).lowercased()
                switch (name, isClosing) {
                case ("br", _):
                    newline()
                case ("p", _):
                    newline(2)
                case ("div", _), ("ul", _), ("ol", _):
                    newline()
                case ("li", false):
                    newline()
                    emit("\u{2022} ")
                    atLineStart = false
                case ("b", false), ("strong", false):
                    var s = stack[stack.count - 1]; s.bold = true; stack.append(s)
                case ("i", false), ("em", false):
                    var s = stack[stack.count - 1]; s.italic = true; stack.append(s)
                case ("a", false):
                    var s = stack[stack.count - 1]
                    if let hrefRange = inner.range(of: "href", options: [.caseInsensitive]) {
                        var j = hrefRange.upperBound
                        while j < inner.endIndex, inner[j] == " " || inner[j] == "=" {
                            j = inner.index(after: j)
                        }
                        if j < inner.endIndex, inner[j] == "\"" || inner[j] == "'" {
                            let quote = inner[j]
                            let start = inner.index(after: j)
                            if let end = inner[start...].firstIndex(of: quote) {
                                s.href = String(inner[start..<end])
                            }
                        }
                    }
                    stack.append(s)
                case ("b", true), ("strong", true), ("i", true), ("em", true), ("a", true):
                    if stack.count > 1 { stack.removeLast() }
                default:
                    break  // unknown tag (span, li close, scope/…): stripped
                }
            }

            var i = html.startIndex
            while i < html.endIndex {
                if html[i] == "<" {
                    guard let close = html[i...].firstIndex(of: ">") else {
                        text(html[i...])
                        break
                    }
                    handleTag(html[html.index(after: i)..<close])
                    i = html.index(after: close)
                } else {
                    let next = html[i...].firstIndex(of: "<") ?? html.endIndex
                    text(html[i..<next])
                    i = next
                }
            }

            while let last = out.characters.last, last == "\n" || last == " " {
                out.removeSubrange(out.index(out.endIndex, offsetByCharacters: -1)..<out.endIndex)
            }
            return out
        }

        /// Decodes `&amp; &lt; &gt; &quot; &apos; &nbsp;` and numeric
        /// (`&#233;` / `&#xE9;`) references; unknown entities pass through.
        private static func decodeEntities(_ s: String) -> String {
            guard s.contains("&") else { return s }
            var result = ""
            result.reserveCapacity(s.count)
            var i = s.startIndex
            while i < s.endIndex {
                if s[i] == "&",
                   let semi = s[i...].firstIndex(of: ";"),
                   s.distance(from: i, to: semi) <= 8 {
                    let entity = String(s[s.index(after: i)..<semi])
                    var replaced: String? = nil
                    switch entity.lowercased() {
                    case "amp": replaced = "&"
                    case "lt": replaced = "<"
                    case "gt": replaced = ">"
                    case "quot": replaced = "\""
                    case "apos": replaced = "'"
                    case "nbsp": replaced = "\u{00A0}"
                    default:
                        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                            if let v = UInt32(entity.dropFirst(2), radix: 16),
                               let sc = Unicode.Scalar(v) { replaced = String(Character(sc)) }
                        } else if entity.hasPrefix("#") {
                            if let v = UInt32(entity.dropFirst()),
                               let sc = Unicode.Scalar(v) { replaced = String(Character(sc)) }
                        }
                    }
                    if let r = replaced {
                        result += r
                        i = s.index(after: semi)
                        continue
                    }
                }
                result.append(s[i])
                i = s.index(after: i)
            }
            return result
        }
    }

    // MARK: - Main Banner Text Parity

    /// Replaces self-closing tags with computed values, mirroring Kotlin Utils.buildText().
    func buildText(
        localize: Localize,
        partnerCount: Int,
        scopeKey: String,
        maxAgeDays: Int,
        isApplyWorkflow: Bool,
        noConsentButton: String,
        closeButton: Bool,
        hasCustomPurposes: Bool,
        customPurposeNames: [String],
        hasGeolocation: Bool,
        dataController: String = "",
        cookieDurationSeconds: Int = 0,
        /// GAP-M16: Web parity (Text3.jsx:34-38) — `<modify/>` resolves to
        /// `modify.icon` locale key when toolbar is active with ICON style;
        /// otherwise `modify.button`.
        toolbarStyleIsIcon: Bool = false,
        isManualDisplay: Bool = false,
        /// FRONT-1283 : `<actors/>` n'a pas la même source selon la phrase qui le porte.
        /// `text4` (« …vous invitons à "appliquer vos choix" à `<actors/>` ») le résout
        /// depuis `text4.partner*` — « ces N nouveaux partenaires » —, alors que
        /// `mode.apply` (« Conformément à vos choix, `<actors/>` pouvons ») le résout
        /// depuis `mode.apply.partner*` — « avec certains partenaires, nous ».
        ///
        /// Le web n'a pas ce problème : chaque composant fournit ses propres tags
        /// (`Text4.jsx` l. 55 contre le bandeau classique). Ce résolveur étant partagé,
        /// il faut le lui dire. Sans ce drapeau la phrase du mode « appliquer les
        /// choix » était agrammaticale : « appliquer vos choix à avec certains
        /// partenaires, nous ».
        isText4Mode: Bool = false
    ) -> String {
        var result = self

        // <mode/>
        let modeKey = isApplyWorkflow ? "mode.apply" : "mode.main"
        result = result.replacingOccurrences(of: "<mode/>", with: localize.getText(key: modeKey))

        // <actors/> — cf. isText4Mode pour la raison des deux sources.
        let actorsKey: String
        if isText4Mode {
            // Pas de garde `partnerCount > 0` ici, volontairement : `Text4.jsx` appelle
            // `getLocaleKey(TEXT4_PARTNER, TEXT4_PARTNER_PLURAL, count)` sans condition, et
            // `getLocaleKey` rend le SINGULIER pour 0 (`count > 1 ? plural : singular`).
            // Retomber sur `mode.apply.we` (« nous ») donnerait « appliquer vos choix à
            // nous », là où le web dit « ce nouveau partenaire ».
            actorsKey = partnerCount > 1 ? "text4.partner_plural" : "text4.partner"
            var actorsText = localize.getText(key: actorsKey)
            actorsText = actorsText.replacingOccurrences(of: "{count}", with: "\(partnerCount)")
            result = result.replacingOccurrences(of: "<actors/>", with: actorsText)
        } else if partnerCount > 0 {
            let isPlural = partnerCount > 1
            if isApplyWorkflow {
                actorsKey = isPlural ? "mode.apply.partner_plural" : "mode.apply.partner"
            } else {
                actorsKey = isPlural ? "mode.main.partner_plural" : "mode.main.partner"
            }
            var actorsText = localize.getText(key: actorsKey)
            actorsText = actorsText.replacingOccurrences(of: "{count}", with: "\(partnerCount)")
            result = result.replacingOccurrences(of: "<actors/>", with: actorsText)
        } else {
            actorsKey = isApplyWorkflow ? "mode.apply.we" : "mode.main.we"
            result = result.replacingOccurrences(of: "<actors/>", with: localize.getText(key: actorsKey))
        }

        // <count/>
        result = result.replacingOccurrences(of: "<count/>", with: "\(partnerCount)")

        // <scope/>
        let scopeText = localize.getText(key: scopeKey)
        result = result.replacingOccurrences(of: "<scope/>", with: scopeText)

        // <location/>
        let locationKey = hasGeolocation ? "geolocation" : "location"
        result = result.replacingOccurrences(of: "<location/>", with: localize.getText(key: locationKey))

        // <modify/> — GAP-M16: Web parity (Text3.jsx:34-38). When toolbar is
        // active with ICON style, use `modify.icon`; otherwise `modify.button`.
        let modifyKey = toolbarStyleIsIcon ? "modify.icon" : "modify.button"
        result = result.replacingOccurrences(of: "<modify/>", with: localize.getText(key: modifyKey))

        // <reject/>
        var rejectText = ""
        if noConsentButton == "REJECT" || noConsentButton == "reject" || isManualDisplay {
            rejectText = localize.getText(key: "reject.reject")
        } else if noConsentButton == "CONTINUE" || noConsentButton == "continue_" {
            rejectText = localize.getText(key: "reject.continue")
        } else if closeButton {
            rejectText = localize.getText(key: "reject.close")
        }
        result = result.replacingOccurrences(of: "<reject/>", with: rejectText)

        // <maxAge/>
        let maxAgeText = getDurationFromDays(maxAgeDays, localize: localize)
        result = result.replacingOccurrences(of: "<maxAge/>", with: maxAgeText)

        // <logoUtiq/>
        result = result.replacingOccurrences(of: "<logoUtiq/>", with: "Utiq")

        // <purposes/>
        result = result.replacingOccurrences(of: "<purposes/>", with: customPurposeNames.joined(separator: ", "))

        // <dataController/>
        result = result.replacingOccurrences(of: "<dataController/>", with: dataController)

        // <duration/>
        if cookieDurationSeconds > 0 {
            result = result.replacingOccurrences(of: "<duration/>", with: getDurationFromSeconds(cookieDurationSeconds))
        } else {
            result = result.replacingOccurrences(of: "<duration/>", with: "")
        }

        return result
    }

    /// Strips classname link tags but keeps inner text.
    /// Mirrors Kotlin Utils.processClassnameTags().
    /// The inner text of `<purposes>...</purposes>` is always preserved.
    /// When [setChoicesStyle] is `.inText` the text is rendered as a
    /// clickable link; otherwise it is plain non-clickable text.
    func processClassnameTags(setChoicesStyle: ThemeSetChoicesStyle = .button) -> String {
        processClassnameTagsStructured(setChoicesStyle: setChoicesStyle).map { $0.text }.joined()
    }

    /// Parses paired classname link tags into ordered segments.
    /// Mirrors Kotlin Utils.processClassnameTagsStructured(). Each segment is a
    /// run of text with an optional link type ("VENDORS", "PURPOSES",
    /// "HOSTNAMES", "WEBSITES", "UTIQ"); plain runs have a nil linkType.
    ///
    /// The inner text of `<purposes>...</purposes>` is always preserved. When
    /// [setChoicesStyle] is `.inText` the text is rendered as a clickable link;
    /// otherwise it is plain non-clickable text and the footer button is visible.
    func processClassnameTagsStructured(
        setChoicesStyle: ThemeSetChoicesStyle = .button
    ) -> [(text: String, linkType: String?)] {
        let input = self
        let tagToLink: [String: String] = [
            "vendors": "VENDORS",
            "purposes": "PURPOSES",
            "hostnames": "HOSTNAMES",
            "websites": "WEBSITES",
            "utiq": "UTIQ"
        ]
        // Match any classname tag capturing (1) tag name and (2) inner text.
        let pattern = "<(vendors|purposes|hostnames|websites|utiq)>(.*?)</\\1>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else {
            return [(text: input, linkType: nil)]
        }

        let ns = input as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var segments: [(text: String, linkType: String?)] = []
        var lastIndex = 0

        regex.enumerateMatches(in: input, options: [], range: fullRange) { match, _, _ in
            guard let match = match else { return }
            let matchRange = match.range
            if matchRange.location > lastIndex {
                let plain = ns.substring(with: NSRange(
                    location: lastIndex,
                    length: matchRange.location - lastIndex
                ))
                segments.append((text: plain, linkType: nil))
            }
            let tagName = ns.substring(with: match.range(at: 1))
            let inner = ns.substring(with: match.range(at: 2))
            let linkType: String?
            if tagName == "purposes", setChoicesStyle == .inText {
                linkType = tagToLink[tagName]
            } else if tagName == "purposes" {
                linkType = nil
            } else {
                linkType = tagToLink[tagName]
            }
            segments.append((text: inner, linkType: linkType))
            lastIndex = matchRange.location + matchRange.length
        }

        if lastIndex < ns.length {
            let tail = ns.substring(with: NSRange(
                location: lastIndex,
                length: ns.length - lastIndex
            ))
            segments.append((text: tail, linkType: nil))
        }
        if segments.isEmpty {
            segments.append((text: input, linkType: nil))
        }
        return segments
    }
}

/// Converts a duration in seconds to a human-readable string.
/// Mirrors Kotlin Utils.getDurationFromSeconds().
func getDurationFromSeconds(_ seconds: Int) -> String {
    var items: [String] = []
    var remaining = seconds

    let days = remaining / 86400
    if days > 0 {
        items.append("\(days) day\(days != 1 ? "s" : "")")
        remaining -= days * 86400
    }

    let hours = (remaining / 3600) % 24
    if hours > 0 {
        items.append("\(hours) hour\(hours != 1 ? "s" : "")")
        remaining -= hours * 3600
    }

    let minutes = (remaining / 60) % 60
    if minutes > 0 {
        items.append("\(minutes) minute\(minutes != 1 ? "s" : "")")
        remaining -= minutes * 60
    }

    let secs = remaining % 60
    if secs > 0 {
        items.append("\(secs) second\(secs != 1 ? "s" : "")")
    }

    return items.joined(separator: " ")
}

/// Formats days as "N months M days" using locale keys.
/// Mirrors Kotlin Utils.getDurationFromDaysLocalized().
func getDurationFromDays(_ days: Int, localize: Localize) -> String {
    var items: [String] = []
    var remaining = days
    let months = remaining / 30
    if months > 0 {
        let monthKey = months > 1 ? "months" : "month"
        items.append("\(months) \(localize.getText(key: monthKey))")
        remaining -= months * 30
    }
    if remaining > 0 {
        let dayKey = remaining > 1 ? "days" : "day"
        items.append("\(remaining) \(localize.getText(key: dayKey))")
    }
    return items.joined(separator: " ")
}

extension Array where Element == KotlinInt {
    /// Converts a Kotlin `List<Int>` (exported as `[KotlinInt]`) to `[Int]`.
    func toIntArray() -> [Int] { map { $0.intValue } }
    /// True if the Kotlin int list contains the given id.
    func containsId(_ id: Int) -> Bool { contains { $0.intValue == id } }
}

/// Modal popup displaying illustration text for a purpose/feature.
/// Mirrors the web CMP's PlusBox component — shows HTML text content
/// from the `${labelKey}.illustrationText` translation key.
struct IllustrationPopup: View {
    let title: String
    let content: String
    let onClose: () -> Void
    @Environment(\.cmpResolvedTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundColor(theme.title)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundColor(theme.text.opacity(0.6))
                }
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                Group {
                    if #available(iOS 15, *), let attrString = content.htmlToAttributedString {
                        Text(attrString)
                    } else {
                        Text(content.strippedMarkup)
                    }
                }
                .font(.subheadline)
                .foregroundColor(theme.text.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .background(theme.background)
    }
}

// MARK: - Availability shims
//
// The sources target iOS 15.0, the minimum of every channel since 2.0.0.
// `cmpPresentationDetents` applies an iOS 16 modifier only where available.
// `cmpTint` and `cmpNoAutocapitalization` predate that minimum: their iOS 15
// branch is now always taken, and the fallbacks are kept only to leave call
// sites untouched.

extension View {
    /// `presentationDetents` shim — no-op below iOS 16 (sheets stay full-height).
    @ViewBuilder
    func cmpPresentationDetents(medium: Bool = false) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents(medium ? [.medium] : [.large])
        } else {
            self
        }
    }

    /// `tint` shim — falls back to `accentColor` below iOS 15.
    @ViewBuilder
    func cmpTint(_ color: Color) -> some View {
        if #available(iOS 15.0, *) {
            self.tint(color)
        } else {
            self.accentColor(color)
        }
    }

    /// `textInputAutocapitalization(.never)` shim — UIKit fallback below iOS 15.
    @ViewBuilder
    func cmpNoAutocapitalization() -> some View {
        if #available(iOS 15.0, *) {
            self.textInputAutocapitalization(.never)
        } else {
            self.autocapitalization(.none)
        }
    }
}
