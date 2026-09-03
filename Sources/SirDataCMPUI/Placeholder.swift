// AMORCE — remplacé en entier à la première release.
//
// `Package.swift` déclare le target `SirDataCMPUI` sur ce chemin, donc il doit
// exister pour que le manifest se charge. `release-ios.yml` fait `rm -rf` puis
// recopie ici les sources SwiftUI du dépôt source, à la version EXACTE du
// binaire — ce fichier disparaît alors. Ne rien y ajouter : tout ce qui vit
// ici est écrasé à chaque release.
