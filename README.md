<p align="center">
  <img src="docs/icon.png" width="128" alt="Icône de Cameras">
</p>

<h1 align="center">Cameras</h1>

<p align="center">
  Régie caméra minimaliste pour macOS.<br>
  Switchez entre vos webcams avec de vraies transitions, directement dans Teams, Zoom et toutes vos apps vidéo.
</p>

---

Cameras vit dans la barre de menus et expose une **caméra virtuelle** : choisissez « Cameras » comme webcam dans votre app de visio, et pilotez ce qu'elle diffuse — changement de caméra avec fondu, incrustation d'une seconde caméra, image d'attente, filigrane — sans que vos interlocuteurs voient les coulisses.

## Fonctionnalités

- **Multi-caméras** : basculez entre vos webcams d'un raccourci, avec transition au choix (fondu, cut, slide, volet, punch, fondu flouté).
- **Scènes** : enregistrez jusqu'à 4 configurations complètes (caméra + cadrage + couleur + incrustation) et rappelez-les d'un geste.
- **Incrustation (PiP)** : une seconde caméra en vignette, position et taille au choix, échangeable avec la caméra principale d'un raccourci.
- **Cadrage et couleur par caméra** : miroir, rotation, zoom continu avec recadrage à la souris, luminosité/contraste/saturation/température — mémorisés pour chaque caméra.
- **Image figée et écran d'attente** : gelez le flux ou affichez votre visuel « je reviens » ; la caméra s'éteint (LED comprise) pendant ce temps.
- **Filigrane** : votre logo incrusté en permanence dans le flux.
- **Capture** : un raccourci et l'image diffusée est enregistrée en PNG sur le Bureau.
- **Aperçu** : une fenêtre montre exactement ce que voit votre app de visio ; une version compacte flotte au-dessus de tout pour surveiller son cadrage en réunion.
- **Sobre par conception** : la capture ne tourne que quand quelqu'un regarde (aperçu ouvert ou client vidéo connecté), capture au format natif des webcams, fréquence réglable 30/24/15 ips, ralentissement automatique si le Mac chauffe. Aucune connexion réseau, tout reste sur votre machine.
- **En français et en anglais.**

## Raccourcis

| Raccourci | Action |
|---|---|
| ⌃⌥1 … ⌃⌥9 | Basculer sur la caméra 1 à 9 |
| ⌃⌥⇧1 … ⌃⌥⇧4 | Rappeler la scène 1 à 4 |
| ⌃⌥0 | Figer / défiger l'image |
| ⌃⌥I | Écran d'attente |
| ⌃⌥P | Échanger caméra active ↔ incrustation |
| ⌃⌥S | Capturer l'image en PNG |

Les modificateurs (⌃⌥ par défaut) se changent dans menu › Réglages › Raccourcis.

## Installation

1. Ouvrez le fichier `.dmg` et glissez **Cameras** dans **Applications**.
2. Lancez Cameras (icône caméra dans la barre de menus) et autorisez l'accès à la caméra.
3. Menu › **Installer la caméra virtuelle**, puis autorisez l'extension dans **Réglages Système › Général › Connexion et extensions**.
4. Dans Teams, Zoom, etc., choisissez la caméra **« Cameras »**.

Nécessite macOS 13 (Ventura) ou plus récent.

## Piloter depuis un Stream Deck ou Raccourcis

Toutes les actions existent en **App Intents** (app Raccourcis, Siri) et via le scheme `cameras://` :

```sh
open "cameras://select/2"        # caméra n°2
open "cameras://scene/1"        # rappelle la scène 1
open "cameras://freeze/toggle"  # figer / défiger
open "cameras://standby/on"     # écran d'attente
open "cameras://swap"           # échange caméra ↔ incrustation
open "cameras://snapshot"       # capture PNG
```

## Compiler soi-même

Xcode 16+ sur macOS 13+. Ouvrez `Cameras.xcodeproj`, sélectionnez votre équipe de développement dans *Signing & Capabilities* (pour les deux cibles), puis ⌘R. L'app fonctionne immédiatement ; l'activation de la caméra virtuelle demande un compte Apple Developer payant et une app installée dans `/Applications` — détails dans [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
