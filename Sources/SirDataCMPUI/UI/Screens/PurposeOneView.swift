import SwiftUI
import SirDataCMP

/// PurposeOne screen — dedicated UI for the cookie-wall purpose 1 acceptance.
///
/// Web CMP parity: `PurposeOne.jsx` (81 lines).
/// Shows a title (`COOKIEWALL_PURPOSE1_TITLE`), body text
/// (`COOKIEWALL_PURPOSE1_TEXT` split by `<br/><br/>`), a close button to
/// dismiss without saving, and a single "Accept Cookies" button that calls
/// `selectPurpose(1, true)` + persists consent + navigates to the Purposes
/// screen.
struct PurposeOneView: View {
    let uiState: ConsentUiState
    let localize: Localize
    let onAccept: () -> Void
    let onClose: () -> Void

    @Environment(\.cmpResolvedTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            // Header with close button (web parity: CloseButton in PurposeOne.jsx)
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .foregroundColor(theme.text.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localize.getText(key: LocaleKey.buttonsClose.key))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Title: COOKIEWALL_PURPOSE1_TITLE
                    Text(localize.getText(key: LocaleKey.cookiewallPurpose1Title.key)
                        .processConditionalTags(
                            purposeIds: Set(uiState.purposes.map { Int($0.id) }),
                            sirdataPurposeIds: Set(uiState.sirdataPurposes.map { Int($0.id) }),
                            specialFeatureIds: Set(uiState.specialFeatures.map { Int($0.id) }),
                            hasLegitimateInterest: uiState.hasLegitimateInterest,
                            hasCustomPurposes: uiState.hasCustomPurposes,
                            hasUtiq: uiState.hasUtiq
                        ))
                        .font(.title3.weight(.semibold))
                        .foregroundColor(theme.title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)

                    // Body text: COOKIEWALL_PURPOSE1_TEXT split by <br/><br/>
                    let bodyText = localize.getText(key: LocaleKey.cookiewallPurpose1Text.key)
                        .processConditionalTags(
                            purposeIds: Set(uiState.purposes.map { Int($0.id) }),
                            sirdataPurposeIds: Set(uiState.sirdataPurposes.map { Int($0.id) }),
                            specialFeatureIds: Set(uiState.specialFeatures.map { Int($0.id) }),
                            hasLegitimateInterest: uiState.hasLegitimateInterest,
                            hasCustomPurposes: uiState.hasCustomPurposes,
                            hasUtiq: uiState.hasUtiq
                        )
                    ForEach(Array(bodyText.components(separatedBy: "<br/><br/>").enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph.strippedMarkup)
                            .font(.subheadline)
                            .foregroundColor(theme.text.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                }
                .padding(20)
            }

            // Footer: single "Accept Cookies" button
            FooterOneAction(
                label: localize.getText(key: LocaleKey.buttonsAcceptCookies.key),
                action: onAccept
            )
        }
        .background(theme.background)
    }
}
