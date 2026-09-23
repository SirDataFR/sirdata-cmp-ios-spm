import SwiftUI

/// A single nested purpose/feature row inside an expanded stack, with an
/// expandable description and its own individual toggle.
///
/// Stateless: renders a `PurposeRowModel` verbatim, reads expansion from the
/// ViewModel-owned `expandedIds` (key = `model.id`, already namespaced with
/// the stack's row id by the ViewModel builder) and emits `ConsentIntent`s
/// through `send`. Mirrors Android's stack nested item rows.
struct StackNestedItemRow: View {
    let model: PurposeRowModel
    /// Live toggle values, looked up by `model.id` / vendor stateKey.
    let toggles: TogglesState
    /// Optional localize closure for partner-count labels and illustrations.
    var localizeText: ((String) -> String)? = nil
    let expandedIds: Set<String>
    let send: (ConsentIntent) -> Void

    @State private var showIllustration = false
    @Environment(\.cmpResolvedTheme) private var theme

    private var isExpanded: Bool { expandedIds.contains(model.id) }
    private var consentToggleState: String {
        model.consentToggleIntent != nil ? (toggles.consent[model.id] ?? "") : ""
    }
    private var liToggleState: String {
        model.liToggleIntent != nil ? (toggles.li[model.id] ?? "") : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                // Two-column deterministic layout: content-hugging clickable
                // (chevron + name) followed by a genuine gesture-less Spacer,
                // then the fixed-width toggle. The leftover row width is
                // provably untappable — matches the web CMP (RowBlockHeader:
                // content-hugging <a>, justify-content: space-between) and
                // Android (Spacer(weight(1f)) with no .clickable) exactly.
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(theme.text.opacity(0.5))
                    Text(model.name)
                        .font(.body)
                        .foregroundColor(theme.text)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    send(.toggleExpand(model.id))
                }
                // Stable hooks for UI tests / QA automation.
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("cmp.row.\(model.id).expand")
                Spacer(minLength: 0)
                if let toggleIntent = model.toggleIntent {
                    ConsentToggle(state: toggles.row[model.id] ?? ToggleState.off,
                                  onToggleChange: { _ in send(toggleIntent) },
                                  accessibilityName: model.name)
                        .fixedSize()
                        .accessibilityIdentifier("cmp.row.\(model.id).toggle")
                }
            }
            if isExpanded, !model.description.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if #available(iOS 15, *), let attr = model.description.htmlToAttributedString {
                        Text(attr)
                            .font(.caption)
                            .foregroundColor(theme.text.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(model.description.strippedMarkup)
                            .font(.caption)
                            .foregroundColor(theme.text.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Examples button — opens in-app popup (web parity: PlusBox)
                    let illustrationText = (localizeText?("\(model.labelKey).illustrationText") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !model.labelKey.isEmpty && !illustrationText.isEmpty {
                        Button {
                            showIllustration = true
                        } label: {
                            Text(localizeText?("examples") ?? "Examples")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(theme.main)
                        }
                        .sheet(isPresented: $showIllustration) {
                            IllustrationPopup(
                                title: localizeText?("illustrations.title") ?? "Examples",
                                content: localizeText?("\(model.labelKey).illustrationText") ?? "",
                                onClose: { showIllustration = false }
                            )
                            .cmpPresentationDetents()
                        }
                    }

                    // Web parity: Consent/LI sub-toggles rendered INSIDE the
                    // PurposeVendorList headers (PurposeVendorsHeader pattern).
                    if !model.consentVendors.isEmpty || !model.liVendors.isEmpty
                        || !consentToggleState.isEmpty || !liToggleState.isEmpty {
                        PurposeVendorList(
                            consentVendors: model.consentVendors,
                            liVendors: model.liVendors,
                            toggles: toggles,
                            localizeText: localizeText,
                            consentVendorCount: model.consentVendorCount,
                            liVendorCount: model.liVendorCount,
                            consentToggleState: consentToggleState,
                            consentToggleIntent: model.consentToggleIntent,
                            liToggleState: liToggleState,
                            liToggleIntent: model.liToggleIntent,
                            baseId: model.id,
                            expandedIds: expandedIds,
                            send: send
                        )
                        .padding(.top, 4)
                    }
                }
                .transition(.opacity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("cmp.row.\(model.id).description")
            }
        }
        .padding(.leading, 32)
    }
}

/// An expandable "activity" (stack) row with a whole-stack toggle.
///
/// Tapping the name expands the row to reveal the stack description, the
/// localized "what it means" label, and the nested purposes / special
/// features — each with their own toggle. Stateless: renders a
/// `StackRowModel` verbatim, expansion read from `expandedIds` (key =
/// `model.id`), interactions emitted as intents. Mirrors Android's `StackRow`.
struct StackRow: View {
    let model: StackRowModel
    /// Live toggle values, looked up by row id.
    let toggles: TogglesState
    var whatItMeansLabel: String = ""
    /// Optional localize closure for nested item labels and illustrations.
    var localizeText: ((String) -> String)? = nil
    let expandedIds: Set<String>
    let send: (ConsentIntent) -> Void

    @State private var showIllustration = false
    @Environment(\.cmpResolvedTheme) private var theme

    private var isExpanded: Bool { expandedIds.contains(model.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                // Two-column deterministic layout — see StackNestedItemRow.
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(theme.text.opacity(0.5))
                    Text(model.name)
                        .font(.headline)
                        .foregroundColor(theme.text)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    send(.toggleExpand(model.id))
                }
                // Stable hooks for UI tests / QA automation.
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("cmp.row.\(model.id).expand")
                Spacer(minLength: 0)
                ConsentToggle(state: toggles.row[model.id] ?? ToggleState.off,
                              onToggleChange: { _ in send(model.toggleIntent) },
                              accessibilityName: model.name)
                    .fixedSize()
                    .accessibilityIdentifier("cmp.row.\(model.id).toggle")
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if #available(iOS 15, *), let attr = model.description.htmlToAttributedString {
                        Text(attr)
                            .font(.subheadline)
                            .foregroundColor(theme.text.opacity(0.7))
                            .padding(.top, 4)
                    } else {
                        Text(model.description.strippedMarkup)
                            .font(.subheadline)
                            .foregroundColor(theme.text.opacity(0.7))
                            .padding(.top, 4)
                    }

                    // Examples button for the stack itself (web parity: PlusBox)
                    let illustrationText = (localizeText?("\(model.labelKey).illustrationText") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !model.labelKey.isEmpty && !illustrationText.isEmpty {
                        Button {
                            showIllustration = true
                        } label: {
                            Text(localizeText?("examples") ?? "Examples")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(theme.main)
                        }
                        .sheet(isPresented: $showIllustration) {
                            IllustrationPopup(
                                title: localizeText?("illustrations.title") ?? "Examples",
                                content: localizeText?("\(model.labelKey).illustrationText") ?? "",
                                onClose: { showIllustration = false }
                            )
                            .cmpPresentationDetents()
                        }
                    }

                    if !model.nestedItems.isEmpty {
                        if !whatItMeansLabel.isEmpty {
                            Text(whatItMeansLabel)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(theme.text)
                        }
                        ForEach(model.nestedItems) { item in
                            StackNestedItemRow(
                                model: item,
                                toggles: toggles,
                                localizeText: localizeText,
                                expandedIds: expandedIds,
                                send: send
                            )
                        }
                    }
                }
                .transition(.opacity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("cmp.row.\(model.id).description")
            }

            if model.showDivider {
                Divider()
                    .padding(.top, 8)
                    .padding(.horizontal, 0)
            }
        }
        .padding(.horizontal, 16)
    }
}
