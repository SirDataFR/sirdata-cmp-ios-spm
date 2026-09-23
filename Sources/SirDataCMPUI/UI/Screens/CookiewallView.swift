import SwiftUI
import SirDataCMP

/// Cookiewall screen — displayed when `cookieWall.active` is true in the
/// publisher config.
///
/// Web CMP parity: `MainCookiewall.jsx` (146 lines).
/// Shows a title (`COOKIEWALL_TITLE`), body text (`COOKIEWALL_TEXT` split by
/// `<br/><br/>` + `COOKIEWALL_CUSTOM_TEXT`), a provider logo (when not
/// white-label), and a single "Modify Choice" button that sets the workflow
/// to `COOKIEWALL_MODIFY` and navigates to the PurposeOne screen.
struct CookiewallView: View {
    let uiState: ConsentUiState
    let localize: Localize
    let onModify: () -> Void

    @Environment(\.cmpResolvedTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Header: publisher logo
                    HStack {
                        CmpLogo(height: 36)
                        Spacer()
                    }
                    .padding(.bottom, 12)

                    // Title: COOKIEWALL_TITLE
                    Text(localize.getText(key: LocaleKey.cookiewallTitle.key)
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

                    // Body text: COOKIEWALL_TEXT split by <br/><br/>
                    let cookiewallText = localize.getText(key: LocaleKey.cookiewallText.key)
                        .processConditionalTags(
                            purposeIds: Set(uiState.purposes.map { Int($0.id) }),
                            sirdataPurposeIds: Set(uiState.sirdataPurposes.map { Int($0.id) }),
                            specialFeatureIds: Set(uiState.specialFeatures.map { Int($0.id) }),
                            hasLegitimateInterest: uiState.hasLegitimateInterest,
                            hasCustomPurposes: uiState.hasCustomPurposes,
                            hasUtiq: uiState.hasUtiq
                        )
                    ForEach(Array(cookiewallText.components(separatedBy: "<br/><br/>").enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph.strippedMarkup)
                            .font(.subheadline)
                            .foregroundColor(theme.text.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }

                    // Custom text: COOKIEWALL_CUSTOM_TEXT
                    let customText = localize.getText(key: LocaleKey.cookiewallCustomText.key)
                    if !customText.isEmpty {
                        Text(customText.strippedMarkup)
                            .font(.subheadline)
                            .foregroundColor(theme.text.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }

                    // Provider logo (hidden in white-label mode)
                    if !theme.whiteLabel {
                        SirDataWatermark()
                            .padding(.top, 12)
                    }
                }
                .padding(20)
            }

            // Footer: single "Modify Choice" button
            FooterOneAction(
                label: localize.getText(key: LocaleKey.buttonsModifyChoice.key),
                action: onModify
            )
        }
        .background(theme.background)
    }
}
