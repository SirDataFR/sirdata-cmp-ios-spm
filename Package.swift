// swift-tools-version:5.9
// ============================================================================
// Manifest SPM de distribution du SDK iOS Sirdata CMP.
//
// AMORCE — les deux placeholders ci-dessous ne sont PAS résolvables. Ils
// existent parce que `release-ios.yml` (dépôt `SirDataFR/sirdata-cmp-mobile`)
// RÉÉCRIT les lignes `url:` et `checksum:` d'un manifest existant, et sort en
// erreur s'il n'en trouve pas exactement une de chaque :
//     Package.swift: url=0 checksum=0 remplacement(s), attendu 1 et 1
// C'est le point 4 de FRONT-1361, et c'était un prérequis bloquant de la
// première release. Ne pas « nettoyer » ces placeholders à la main : la
// première release les remplace.
//
// L'HÔTE de l'URL est celui que FRONT-1361 VEUT, pas celui que le workflow
// écrit aujourd'hui. Son script construit l'URL depuis $GITHUB_REPOSITORY,
// donc il posera pour l'instant celle du dépôt PRIVÉ `sirdata-cmp-mobile`,
// dont les assets de release ne sont pas servis anonymement. C'est le point 1
// de FRONT-1361, NON LIVRÉ : ne pas lire cet hôte-ci comme la preuve qu'il
// l'est.
//
// Règles à ne pas casser :
//   - Le binaryTarget DOIT s'appeler "SirDataCMP" : SPM exige que le nom du
//     target corresponde au SirDataCMP.xcframework contenu dans le zip, et le
//     module Swift du binaire porte ce nom (`import SirDataCMP`).
//   - Le zip doit contenir `SirDataCMP.xcframework/` à sa racine
//     (le workflow utilise `ditto -c -k --keepParent`).
//   - Les sources SwiftUI (module `SirDataCMPUI`) sont synchronisées depuis
//     `ios/SirDataCMP/Sources/SirDataCMP/` du dépôt source vers
//     `Sources/SirDataCMPUI/` ici, à chaque release, à la version EXACTE du
//     binaire — jamais indépendamment. Un binaire et des sources désaccordés
//     compilent parfaitement et livrent l'ancienne logique sans aucun signal
//     (FRONT-1274).
// ============================================================================
import PackageDescription

let package = Package(
    name: "SirDataCMP",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        // Un seul produit, deux modules :
        //   import SirDataCMP    // cœur KMP : IosCMPApi, TCF/GPP/USP
        //   import SirDataCMPUI  // SwiftUI : ConsentView
        .library(
            name: "SirDataCMP",
            targets: ["SirDataCMP", "SirDataCMPUI"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "SirDataCMP",
            url: "https://github.com/SirDataFR/sirdata-cmp-ios-spm/releases/download/2.0.0/SirDataCMP-2.0.0.xcframework.zip",
            checksum: "542939c03d457a23724014d7a7b530c86589e487cf6e2c58118a163ae634d5fe"
        ),
        .target(
            name: "SirDataCMPUI",
            dependencies: ["SirDataCMP"],
            path: "Sources/SirDataCMPUI"
        )
    ]
)
