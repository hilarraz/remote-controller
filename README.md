# Remote

Télécommande Apple TV native pour macOS (Swift / SwiftUI), inspirée de l'app « Remote » d'iOS.

- Pavé tactile (glisser à la souris ou à deux doigts sur le trackpad, clic = sélection, clic maintenu = appui long) ou pavé directionnel
- Boutons Retour, TV, Lecture/Pause, Rechercher, Volume ±, ±10 s, veille/réveil — l'appui long fonctionne comme sur la vraie télécommande
- Saisie de texte en direct dans le champ actif de l'Apple TV, bouton Coller
- Notification quand l'Apple TV attend du texte alors que la télécommande n'est pas à l'écran : on y répond pour écrire sur la TV, ou on clique pour ouvrir le clavier
- Raccourci global (⌃⌥V par défaut) pour coller le presse-papiers du Mac sur l'Apple TV depuis n'importe quelle app
- Raccourcis clavier quand la fenêtre est active (flèches, ↩, ⎋, Espace, H, J/L, +/−, /, K, A, ⌘V)
- Lanceur d'apps avec icônes et favoris (clic droit), affichés aussi sous les boutons de la télécommande
- Lecture en cours : titre, artiste/série, pochette, progression (cliquer ou glisser pour changer de position), précédent/suivant
- Actions pour Raccourcis, Spotlight et Siri : ouvrir une app, lecture/pause, coller, écrire, veille/réveil, appuyer sur un bouton
- Fenêtre + icône dans la barre des menus

## Compiler et lancer

Prérequis : macOS 26 ou plus récent, Xcode 26 ou plus récent.

```sh
open Remote.xcodeproj   # puis ⌘R
```

ou en ligne de commande :

```sh
xcodebuild -project Remote.xcodeproj -scheme Remote -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/Remote.app
```

Au premier lancement, macOS demande l'accès au **réseau local** : il faut l'accepter (sinon Réglages Système › Confidentialité et sécurité › Réseau local).

## Jumelage

La première connexion affiche un code à 4 chiffres sur le téléviseur, à saisir dans l'app. Le même jumelage sert aussi à « Lecture en cours » (AirPlay) : un seul code suffit.

Les clés de jumelage sont enregistrées dans `~/Library/Application Support/Remote/store.json` (lisible par vous seul). Le Mac apparaît dans Réglages › Télécommandes et appareils de l'Apple TV ; supprimer l'appareil là-bas révoque l'accès.

## Organisation

| Dossier | Contenu |
| --- | --- |
| `AppleTVKit/` | Package Swift indépendant de l'interface : découverte Bonjour, jumelage HomeKit (SRP-6a, Ed25519, X25519, ChaCha20-Poly1305), protocole Companion (OPACK), saisie de texte (RTI / NSKeyedArchiver), tunnel AirPlay 2 et messages MediaRemote (protobuf) |
| `AppleTVKit/Sources/atvctl/` | Outil en ligne de commande pour tester le protocole (`scan`, `pair`, `apps`, `text`, `nowplaying`, `raw`…) |
| `RemoteController/` | App SwiftUI (modèle, vues, raccourcis, icône) |
| `Config/Info.plist` | Autorisations réseau local / Bonjour |

Le protocole a été implémenté en s'appuyant sur [pyatv](https://github.com/postlund/pyatv), qui a documenté les protocoles Companion et MRP.

## Développement

```sh
cd AppleTVKit
swift test                              # tests unitaires (encodages, SRP, HTTP, protobuf, lecture en cours)
swift run atvctl scan                   # liste les Apple TV
ATVKIT_DEBUG=1 swift run atvctl watch   # affiche tous les messages échangés
```

À chaque push sur `main`, GitHub Actions lance les tests et compile l'app (`.github/workflows/ci.yml`).

`atvctl` garde ses propres clés dans `~/.config/atvctl/store.json` (même format que l'app).
