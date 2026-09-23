import SwiftUI
import SirDataCMP

/// T-V06: A single purpose item with optional description and data retention.
/// Mirrors Android's `VendorPurposeItem` and web VendorPurpose.jsx — collapsed shows name + status,
/// expanded shows description + retention. The status TEXT is live: looked up
/// in `TogglesState.acceptance[statusKey]` at render.
struct VendorPurposeItem {
    let name: String
    /// Key into `TogglesState.acceptance` for the live status label.
    let statusKey: String
    var description: String = ""
    var retention: String? = nil
}

/// T-V02: Storage Disclosure summary data for a TCF vendor row.
struct VendorStorageDisclosure {
    let label: String
    let description: String
    let url: String?
}

/// T-V03: Read-only info section inside a partner's expanded detail.
/// Used for Special Purposes & Features and Data Categories.
/// No toggle — just a label and items.
///
/// Web parity (`IabTcfVendor.jsx`): these lines are the SAME `VendorPurpose`
/// component as the consent/LI purposes — name, description revealed on tap —
/// minus the acceptance status, which the web omits by passing no `stateLabel`.
/// They therefore carry a description, not just a name.
struct VendorInfoSection {
    let label: String
    let items: [VendorInfoItem]
}

/// One read-only line of a `VendorInfoSection`: a special purpose, a feature or
/// a data category. Retention is nil for features and data categories.
/// Mirrors Android's `VendorInfoItem`.
struct VendorInfoItem {
    let name: String
    var description: String = ""
    var retention: String? = nil
}

/// A partner row matching the web/Android CMP layout:
/// collapsed = name + optional "IAB TCF" badge + one combined toggle;
/// expanded = privacy policy link, then a consent section and a legitimate
/// interest section, each with its own toggle and covered purposes.
///
/// Stateless: renders a `PartnerEntryData` verbatim; row and nested purpose
/// expansion live in the ViewModel-owned `expandedIds` (row key = `entry.id`,
/// nested keys are namespaced below it), so the enclosing LazyVStack can
/// recycle cells without ever dropping expand state. Toggles emit
/// `ConsentIntent`s whose targets are resolved from the LIVE store state.
/// Mirrors Android's `VendorRow`.
struct VendorRow: View {
    let entry: PartnerEntryData
    /// Live toggle/acceptance values (combined toggle, section toggles and
    /// per-purpose status labels are looked up by key).
    let toggles: TogglesState
    var privacyPolicyLabel: String = "Privacy policy"
    var localize: Localize? = nil
    let expandedIds: Set<String>
    let send: (ConsentIntent) -> Void

    @State private var showStorageSheet = false
    @Environment(\.cmpResolvedTheme) private var theme

    private var isExpanded: Bool { expandedIds.contains(entry.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed row: name [badge] .......... toggle
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Text(entry.name)
                        .font(.body)
                        .foregroundColor(theme.text)
                        .lineLimit(2)
                    if entry.isIabTcf {
                        Text("IAB TCF")
                            .font(.caption2)
                            .foregroundColor(theme.text.opacity(0.8))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.text.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { send(.toggleExpand(entry.id)) }

                // T-V04: SP-only vendors have no combined toggle.
                if !entry.spOnly, let combinedIntent = entry.combinedIntent {
                    ConsentToggle(state: toggles.row[ToggleKey.partnerRow(entry.id)] ?? ToggleState.off,
                                  onToggleChange: { _ in send(combinedIntent) },
                                  accessibilityName: entry.name)
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    if !entry.policyUrl.isEmpty, let url = URL(string: entry.policyUrl) {
                        Link(destination: url) {
                            Text(privacyPolicyLabel)
                                .font(.subheadline)
                                .underline()
                                .foregroundColor(theme.text)
                        }
                        .padding(.vertical, 4)
                    }
                    if let consentSection = entry.consentSection {
                        channelSection(consentSection, sectionKey: "consent")
                    }
                    if let liSection = entry.liSection {
                        channelSection(liSection, sectionKey: "li")
                    }
                    if let specialPurposesSection = entry.specialPurposesSection {
                        infoSection(specialPurposesSection, sectionKey: "spf")
                    }
                    if let dataCategoriesSection = entry.dataCategoriesSection {
                        infoSection(dataCategoriesSection, sectionKey: "dc")
                    }
                    if let nonTcConsentSection = entry.nonTcConsentSection {
                        channelSection(nonTcConsentSection, sectionKey: "nonTcConsent")
                    }
                    if let nonTcLISection = entry.nonTcLISection {
                        channelSection(nonTcLISection, sectionKey: "nonTcLI")
                    }
                    // T-V06: LegIntClaim link
                    if let legIntClaimUrl = entry.legIntClaimUrl, !legIntClaimUrl.isEmpty, !entry.legIntClaimLabel.isEmpty,
                       let url = URL(string: legIntClaimUrl) {
                        Link(destination: url) {
                            Text(entry.legIntClaimLabel)
                                .font(.subheadline)
                                .underline()
                                .foregroundColor(theme.text)
                        }
                        .padding(.vertical, 4)
                    }
                    if let storageDisclosure = entry.storageDisclosure {
                        storageDisclosureSection(storageDisclosure)
                    }
                }
                .padding(.top, 4)
                .transition(.opacity)
            }

            Divider()
                .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func channelSection(_ section: VendorPurposeSectionData, sectionKey: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // T-V08: Render non-TCF label with interpolated vendor name as clickable link
            if let vendorName = section.vendorName, let vendorPolicyUrl = section.vendorPolicyUrl,
               section.label.contains("<vendorName/>") {
                renderNonTcfLabel(section, vendorName: vendorName, vendorPolicyUrl: vendorPolicyUrl)
            } else {
                HStack {
                    Text(section.label)
                        .font(.subheadline)
                        .foregroundColor(theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if section.showToggle, let toggleIntent = section.toggleIntent {
                        ConsentToggle(state: toggles.row[section.stateKey] ?? ToggleState.off,
                                      onToggleChange: { _ in send(toggleIntent) },
                                      accessibilityName: section.label)
                    }
                }
            }
            if !section.purposes.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(section.purposes.enumerated()), id: \.offset) { index, item in
                        ExpandablePurposeItem(
                            item: item,
                            statusText: toggles.acceptance[item.statusKey] ?? "",
                            theme: theme,
                            expandKey: "\(entry.id)_\(sectionKey)_p\(index)",
                            expandedIds: expandedIds,
                            send: send
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.border.opacity(0.7), lineWidth: 1)
                )
            }
        }
        .padding(.top, 8)
    }

    /// T-V08: Render a non-TCF label with `<vendorName/>` replaced by a clickable link.
    /// Includes a ConsentToggle when `section.showToggle` is true (FRONT-1261 fix).
    @ViewBuilder
    private func renderNonTcfLabel(_ section: VendorPurposeSectionData, vendorName: String, vendorPolicyUrl: String) -> some View {
        HStack {
            if let url = URL(string: vendorPolicyUrl) {
                let parts = section.label.components(separatedBy: "<vendorName/>")
                if parts.count == 2 {
                    (Text(parts[0])
                        .font(.subheadline)
                        .foregroundColor(theme.text)
                     +
                     Text(vendorName)
                        .font(.subheadline)
                        .underline()
                        .foregroundColor(theme.text)
                     +
                     Text(parts[1])
                        .font(.subheadline)
                        .foregroundColor(theme.text))
                    // iOS 14 compat: \.openURL is only writable from iOS 15 —
                    // and the concatenated Text carries no tappable link anyway,
                    // so open the vendor policy on tap directly.
                    .contentShape(Rectangle())
                    .onTapGesture { UIApplication.shared.open(url) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(section.label.replacingOccurrences(of: "<vendorName/>", with: vendorName))
                        .font(.subheadline)
                        .foregroundColor(theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(section.label.replacingOccurrences(of: "<vendorName/>", with: vendorName))
                    .font(.subheadline)
                    .foregroundColor(theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if section.showToggle, let toggleIntent = section.toggleIntent {
                ConsentToggle(state: toggles.row[section.stateKey] ?? ToggleState.off,
                              onToggleChange: { _ in send(toggleIntent) },
                              accessibilityName: section.label)
            }
        }
    }

    /// Web parity (`IabTcfVendor.jsx`): every line here is the same expandable
    /// `VendorPurpose` as a consent purpose — chevron-less tap revealing the
    /// description — only without the acceptance status. Rendering them as bare
    /// labels dropped every special purpose / feature / data category
    /// description from the screen.
    @ViewBuilder
    private func infoSection(_ section: VendorInfoSection, sectionKey: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.label)
                .font(.subheadline)
                .foregroundColor(theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !section.items.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                        ExpandablePurposeItem(
                            item: VendorPurposeItem(name: item.name, statusKey: "",
                                                    description: item.description, retention: item.retention),
                            statusText: "",
                            theme: theme,
                            expandKey: "\(entry.id)_\(sectionKey)_i\(index)",
                            expandedIds: expandedIds,
                            send: send
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.border.opacity(0.7), lineWidth: 1)
                )
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func storageDisclosureSection(_ disclosure: VendorStorageDisclosure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Web parity: single font size for label and description (rowBlockText)
            Text(disclosure.label)
                .font(.subheadline)
                .foregroundColor(theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(disclosure.description)
                .font(.subheadline)
                .foregroundColor(theme.text.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let urlStr = disclosure.url, !urlStr.isEmpty {
                // Web parity: PlusLink — "More" link that opens a popup instead of browser
                Button {
                    showStorageSheet = true
                } label: {
                    Text(localize?.getText(key: LocaleKey.more.key) ?? "More")
                        .font(.subheadline)
                        .underline()
                        .foregroundColor(theme.text)
                }
            }
        }
        .padding(.top, 8)
        .sheet(isPresented: $showStorageSheet) {
            StorageDisclosureSheet(
                url: disclosure.url,
                localize: localize
            )
        }
    }
}

/// Fetches JSON from deviceStorageDisclosureUrl, parses it, and displays
/// the formatted storage disclosure entries. Mirrors web StorageDisclosure.jsx.
private struct StorageDisclosureSheet: View {
    let url: String?
    let localize: Localize?

    @State private var isLoading = true
    @State private var hasError = false
    @State private var entries: [StorageDisclosureEntry] = []
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.cmpResolvedTheme) private var theme

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isLoading {
                        Text("Loading...")
                            .font(.subheadline)
                            .foregroundColor(theme.text.opacity(0.5))
                    } else if hasError || entries.isEmpty {
                        Text(localize?.getText(key: LocaleKey.storageError.key) ?? "Error")
                            .font(.subheadline)
                            .foregroundColor(Color.red)
                    } else {
                        // Use the existing StorageDisclosureView component
                        if let loc = localize {
                            StorageDisclosureView(
                                disclosedItems: entries,
                                localize: loc,
                                isLoading: false,
                                hasError: false
                            )
                        } else {
                            // Fallback: plain text display
                            ForEach(0..<entries.count, id: \.self) { i in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entries[i].identifier).font(.caption.weight(.bold))
                                    Text(entries[i].type).font(.caption)
                                    Text(entries[i].maxAgeText).font(.caption)
                                    if let d = entries[i].domain {
                                        Text(d).font(.caption)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(localize?.getText(key: LocaleKey.storageTitle.key) ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localize?.getText(key: LocaleKey.buttonsClose.key) ?? "Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .onAppear {
            fetchStorageDisclosure()
        }
    }

    private func fetchStorageDisclosure() {
        guard let urlStr = url, let url = URL(string: urlStr) else {
            hasError = true
            isLoading = false
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                guard let data = data, error == nil else {
                    hasError = true
                    isLoading = false
                    return
                }
                let parsed = parseStorageDisclosureJson(data: data)
                entries = parsed
                hasError = parsed.isEmpty
                isLoading = false
            }
        }.resume()
    }

    private func parseStorageDisclosureJson(data: Data) -> [StorageDisclosureEntry] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let disclosures = json["disclosures"] as? [[String: Any]] else {
            return []
        }
        return disclosures.compactMap { item in
            let identifier = item["identifier"] as? String ?? ""
            let type = item["type"] as? String ?? ""
            let maxAgeSeconds = item["maxAgeSeconds"] as? Int ?? -1
            let maxAgeText: String
            if maxAgeSeconds > 0 {
                maxAgeText = getDurationFromSeconds(maxAgeSeconds)
            } else if maxAgeSeconds == 0 {
                maxAgeText = localize?.getText(key: LocaleKey.session.key) ?? "Session"
            } else {
                maxAgeText = ""
            }
            let cookieRefresh: String?
            if item["cookieRefresh"] as? Bool == true {
                cookieRefresh = localize?.getText(key: LocaleKey.storageCookieRefresh.key)
            } else {
                cookieRefresh = nil
            }
            let domain = (item["domain"] as? String)?.nilIfEmpty
            let purposeIds = item["purposes"] as? [Int] ?? []
            let purposes = purposeIds.map { id in
                localize?.getText(key: "purpose\(id).name") ?? "Purpose \(id)"
            }
            return StorageDisclosureEntry(
                identifier: identifier,
                type: type,
                maxAgeText: maxAgeText,
                cookieRefresh: cookieRefresh,
                domain: domain,
                purposes: purposes
            )
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// T-V06: An expandable purpose item that shows description + retention when tapped.
/// Expansion is parent-owned (ViewModel `expandedIds`) so LazyVStack recycling
/// can never reset it. Mirrors web VendorPurpose.jsx behavior.
private struct ExpandablePurposeItem: View {
    let item: VendorPurposeItem
    /// Live status label ("Accepted"/"Rejected"/…), resolved by the caller
    /// from `TogglesState.acceptance[item.statusKey]`.
    let statusText: String
    let theme: ResolvedTheme
    let expandKey: String
    let expandedIds: Set<String>
    let send: (ConsentIntent) -> Void

    private var isExpanded: Bool { expandedIds.contains(expandKey) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.name)
                    .font(.caption)
                    .foregroundColor(theme.text.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Web parity (VendorPurpose.jsx): the status span exists only when a
                // `stateLabel` is passed — special purposes, features and data
                // categories carry none.
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundColor(theme.text.opacity(0.55))
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture {
                if !item.description.isEmpty || item.retention != nil {
                    send(.toggleExpand(expandKey))
                }
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    if !item.description.isEmpty {
                        Text(item.description)
                            .font(.caption2)
                            .foregroundColor(theme.text.opacity(0.6))
                    }
                    if let retention = item.retention {
                        Text(retention)
                            .font(.caption2)
                            .foregroundColor(theme.text.opacity(0.55))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
    }
}
