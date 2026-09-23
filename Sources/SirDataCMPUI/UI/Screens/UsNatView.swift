import SwiftUI
import SirDataCMP

/// L'écran US « Privacy Choices », port de `UsNat.jsx`.
///
/// **Aucune règle n'est dérivée ici** : tout vient de [UsNatScreenData], projeté par
/// `ConsentViewModel.buildUsNatData()` depuis `com.sirdata.cmp.usnat.UsNatScreen`. Cette vue
/// choisit une mise en page, pas un comportement — et surtout pas ce qui est enregistré :
/// seul `onSave` persiste, `onClose` n'écrit rien (cf. la KDoc de `usNatPendingOptOut`).
///
/// La branche GPC du web est absente, et c'est délibéré : le SDK in-app ne détecte aucun
/// signal Global Privacy Control, donc le paragraphe `usnat.gpc`, le libellé « Close » et
/// son action seraient inatteignables — du code mort-né, que ce dépôt a déjà payé deux fois
/// (`WorkflowEngine`, `ConsentScreenDecade`).
struct UsNatView: View {
    let data: UsNatScreenData
    let privacyPolicyUrl: String
    let onToggle: () -> Void
    let onSave: () -> Void
    let onClose: () -> Void

    @Environment(\.cmpResolvedTheme) private var theme
    @State private var showStates = false

    /// Le lien qui déclenche une ACTION plutôt qu'une navigation.
    ///
    /// Même convention que le bandeau (`MainBannerView.attributedText`) : un lien réel garde
    /// son URL et part en `.systemAction`, seul le schéma `cmp-nav` est intercepté. La
    /// comparaison porte ici sur l'URL ENTIÈRE plutôt que sur le schéma, pour qu'un seul
    /// littéral serve à la fois à poser le lien et à le reconnaître — deux littéraux qu'aucun
    /// compilateur ne rapproche sont la classe de défaut que ce dépôt documente cinq fois.
    fileprivate static let statesLink = "cmp-nav://usnat-states"

    var body: some View {
        if #available(iOS 15, *) {
            content
                .environment(\.openURL, OpenURLAction { url in
                    guard url.absoluteString == Self.statesLink else { return .systemAction }
                    showStates = true
                    return .handled
                })
        } else {
            // iOS 14 : `AttributedString` et `OpenURLAction` demandent iOS 15, donc les trois
            // paragraphes se rendent en texte brut — libellés conservés, liens inertes, liste
            // d'États inatteignable. Ce qui compte reste entier : le contrôle d'opposition et
            // le bouton d'enregistrement. Même dégradation que le bandeau.
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    if !data.intro.isEmpty {
                        UsNatParagraph(text: data.intro, tag: "policy", href: privacyPolicyUrl)
                            .padding(.bottom, 12)
                    }

                    UsNatParagraph(text: data.states, tag: "usnatStates", href: Self.statesLink)

                    if data.showsPara && !data.para.isEmpty {
                        Text(data.para)
                            .font(.subheadline)
                            .foregroundColor(theme.text.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                    }

                    if data.anyOffered {
                        UsNatOptOutRow(label: data.toggleLabel, optedOut: data.optedOut, onToggle: onToggle)
                            .padding(.top, 16)
                    }

                    UsNatParagraph(
                        text: data.more,
                        tag: "iab",
                        href: CmpConstants.shared.IAB_PRIVACY_URL
                    )
                    .padding(.top, 16)
                }
                .padding(20)
            }

            // Le bouton ne s'affiche que si la modale a quelque chose à ENREGISTRER. Sans
            // opposition offerte, l'écran est une notice purement informative : titre, phrase
            // d'États, renvois, fermeture.
            if data.showsSave {
                FooterOneAction(label: data.saveLabel, action: onSave)
            }
        }
        .background(theme.background)
        .sheet(isPresented: $showStates) {
            UsNatStatesSheet(title: data.statesTitle, states: data.coveredStates, closeLabel: data.closeLabel, theme: theme)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(data.title)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(theme.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .foregroundColor(theme.text.opacity(0.6))
                }
                .buttonStyle(.plain)
                // Un libellé lu dans le jeu **US** — cf. la KDoc de `UsNatScreenData.closeLabel`.
                .accessibilityLabel(data.closeLabel)
            }

            Text(data.subtitle)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
                .padding(.bottom, 12)
        }
    }
}

/// Un paragraphe dont une balise porte un lien.
///
/// Le web rend ses trois renvois EN LIGNE (`<policy>`, `<usnatStates>`, `<iab>`), donc le
/// libellé doit rester dans le flux du texte : d'où un `AttributedString` plutôt qu'un bouton
/// à côté. Deux replis, tous deux volontaires — balise absente (`usnat.statesAll` n'en porte
/// aucune) ou `href` vide (éditeur sans politique de confidentialité) rendent le texte brut,
/// là où Compose laisserait un lien stylé mais inerte.
///
/// La PREMIÈRE occurrence de la balise seulement est liée, quand le web fait un remplacement
/// global. Vérifié sur les 23 textes servis : chacun en porte au plus une. Un traducteur qui
/// en ajouterait une seconde la verrait ressortir en balises visibles.
private struct UsNatParagraph: View {
    let text: String
    let tag: String
    let href: String

    @Environment(\.cmpResolvedTheme) private var theme

    var body: some View {
        Group {
            if #available(iOS 15, *), let attr = attributed {
                Text(attr)
            } else {
                Text(text.strippedMarkup)
            }
        }
        .font(.subheadline)
        .foregroundColor(theme.text.opacity(0.85))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @available(iOS 15, *)
    private var attributed: AttributedString? {
        guard let parts = Self.split(text, tag: tag), let url = URL(string: href) else { return nil }
        var out = AttributedString(parts.before)
        var link = AttributedString(parts.label)
        link.link = url
        link.foregroundColor = theme.main
        link.underlineStyle = .single
        out.append(link)
        out.append(AttributedString(parts.after))
        return out
    }

    private static func split(_ text: String, tag: String) -> (before: String, label: String, after: String)? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>"),
              open.upperBound <= close.lowerBound else { return nil }
        return (
            String(text[text.startIndex..<open.lowerBound]),
            String(text[open.upperBound..<close.lowerBound]),
            String(text[close.upperBound...])
        )
    }
}

/// Le CONTRÔLE UNIQUE de l'écran US.
///
/// Un seul geste couvre toutes les oppositions offertes — l'écran ne déroule jamais la liste
/// des activités, c'est le store qui fait la synthèse (`setCcpaOptOut`).
private struct UsNatOptOutRow: View {
    let label: String
    let optedOut: Bool
    let onToggle: () -> Void

    @Environment(\.cmpResolvedTheme) private var theme

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: optedOut ? "checkmark.square.fill" : "square")
                    .foregroundColor(optedOut ? theme.main : theme.text.opacity(0.5))
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(optedOut ? [.isButton, .isSelected] : .isButton)
    }
}

/// La modale secondaire des États couverts.
///
/// Les noms restent en ANGLAIS, non localisés : c'est ce que le web rend, et les traduire
/// ferait diverger les deux écrans sur une liste que la loi désigne par son nom propre.
private struct UsNatStatesSheet: View {
    let title: String
    let states: [String]
    let closeLabel: String
    let theme: ResolvedTheme

    // iOS 14 compat: \.dismiss requires iOS 15.
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                        Text(state)
                            .font(.subheadline)
                            .foregroundColor(theme.text)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle(title.isEmpty ? " " : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(closeLabel) { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}
