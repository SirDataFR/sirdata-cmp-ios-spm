import SwiftUI
import SirDataCMP

/// Web CMP parity: StorageDisclosure snippet (StorageDisclosure.jsx).
///
/// Displays device storage information fetched from `deviceStorageDisclosureUrl`.
/// Used inside the VendorsView.
struct StorageDisclosureEntry {
    let identifier: String
    let type: String
    let maxAgeText: String
    let cookieRefresh: String?
    let domain: String?
    let purposes: [String]
}

struct StorageDisclosureView: View {
    let disclosedItems: [StorageDisclosureEntry]
    let localize: Localize
    let isLoading: Bool
    let hasError: Bool

    @Environment(\.cmpResolvedTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                Text("Loading...")
                    .font(.caption)
                    .foregroundColor(theme.text.opacity(0.5))
            } else if hasError || disclosedItems.isEmpty {
                Text(localize.getText(key: LocaleKey.storageError.key))
                    .font(.caption)
                    .foregroundColor(Color.red)
            } else {
                ForEach(0..<disclosedItems.count, id: \.self) { index in
                    disclosureItemView(disclosedItems[index])
                }
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func disclosureItemView(_ entry: StorageDisclosureEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Name
            HStack(spacing: 4) {
                Text(localize.getText(key: LocaleKey.storageName.key))
                    .font(.caption)
                Text(":")
                    .font(.caption)
                Text(entry.identifier)
                    .font(.caption.weight(.bold))
                    .foregroundColor(theme.main)
            }
            // Type
            HStack(spacing: 4) {
                Text(localize.getText(key: LocaleKey.storageType.key))
                    .font(.caption)
                Text(":")
                    .font(.caption)
                Text(entry.type)
                    .font(.caption.weight(.bold))
                    .foregroundColor(theme.main)
            }
            // Max Age
            HStack(spacing: 4) {
                Text(localize.getText(key: LocaleKey.storageMaxAge.key))
                    .font(.caption)
                Text(":")
                    .font(.caption)
                Text(entry.maxAgeText)
                    .font(.caption.weight(.bold))
                    .foregroundColor(theme.main)
                if let refresh = entry.cookieRefresh {
                    Text(refresh)
                        .font(.caption)
                }
            }
            // Domain (if present)
            if let domain = entry.domain {
                HStack(spacing: 4) {
                    Text(localize.getText(key: LocaleKey.storageDomain.key))
                        .font(.caption)
                    Text(":")
                        .font(.caption)
                    Text(domain)
                        .font(.caption.weight(.bold))
                        .foregroundColor(theme.main)
                }
            }
            // Purposes
            if !entry.purposes.isEmpty {
                Text(localize.getText(key: LocaleKey.storagePurposes.key))
                    .font(.caption)
                ForEach(entry.purposes, id: \.self) { purpose in
                    HStack {
                        Text("  •")
                            .font(.caption)
                        Text(purpose)
                            .font(.caption)
                            .foregroundColor(theme.text.opacity(0.75))
                    }
                }
            }
        }
    }
}
