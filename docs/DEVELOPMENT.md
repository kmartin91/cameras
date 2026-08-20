# Développement

Notes techniques pour compiler, comprendre et distribuer Cameras.

## Build

- macOS 13+ (Ventura), Xcode 16+.
- Ouvrir `Cameras.xcodeproj`, régler votre équipe de développement (*Signing & Capabilities*, cibles `Cameras` et `CameraExtension`), puis ⌘R. En CLI :

```sh
xcodebuild -project Cameras.xcodeproj -target Cameras -configuration Debug build DEVELOPMENT_TEAM=VOTRE_TEAM_ID
```

L'app group et le service Mach de l'extension utilisent `$(TeamIdentifierPrefix)` : aucun identifiant d'équipe n'est codé en dur, tout suit l'équipe sélectionnée.

## Architecture

```
Cameras/
├── CamerasApp.swift             MenuBarExtra + fenêtres d'aperçu + AppDelegate (URLs cameras://)
├── CameraManager.swift          découverte, permission, hotplug, scènes, cycle de vie des AVCaptureSession
├── Pipeline.swift               ★ compositing : frames brutes → transition/PiP/filigrane/attente → frames composées
├── PreviewWindow.swift          aperçus (NSView/CALayer) + contrôles de cadrage et de couleur
├── VirtualCameraSink.swift      pousse les frames composées vers l'extension via CoreMediaIO
├── SystemExtensionManager.swift installe/active l'extension (OSSystemExtensionRequest)
├── HotKeys.swift                raccourcis globaux (Carbon RegisterEventHotKey, modificateurs configurables)
├── AppIntents.swift             actions Raccourcis (sélection, figer, attente, swap, scène, capture)
└── Localizable.xcstrings        catalogue fr (source) → en

CameraExtension/
├── main.swift                   bootstrap du CMIOExtensionProvider
└── CameraExtensionProvider.swift caméra virtuelle « Cameras » : stream source (lu par Teams/Zoom) + stream sink (alimenté par l'app)

Config/
├── Cameras.entitlements         system-extension.install + device.camera + app group
├── Cameras-Info.plist           CFBundleURLTypes (scheme cameras://), fusionné avec l'Info.plist généré
├── CameraExtension.entitlements sandbox + caméra + app group
└── CameraExtension-Info.plist   CMIOExtensionMachServiceName ($(TeamIdentifierPrefix)…)
```

### Pipeline de données

```
 AVCaptureDevice A ──┐  CVPixelBuffer (YUV 420 bi-planaire, preset 720p/1080p, 15–30 fps)
 (session active)    ├──────────────▶ Pipeline ──────▶ rendu UNIQUE vers CVPixelBuffer IOSurface (BGRA) :
 AVCaptureDevice B ──┘                 │ aspect-fill + miroir/rotation  ├─▶ aperçus (IOSurface → CALayer.contents, zéro copie)
 (vivante uniquement                   │ zoom/pan + correction couleur └─▶ virtualSink → VirtualCameraSink → extension CMIO
  pendant la transition)               │ 6 transitions, smoothstep
 AVCaptureDevice C ─ (PiP, VGA 15 ips)▶│ vignette PiP + filigrane composés
```

macOS n'a pas `AVCaptureMultiCamSession`, donc une `AVCaptureSession` par caméra ; seule l'active tourne. Au switch, `CameraManager` démarre la session cible, `Pipeline` continue d'afficher l'ancienne jusqu'à la première frame de la nouvelle, lance le crossfade, puis notifie (`onTransitionEnded`) pour stopper l'ancienne session.

Tout passe par `Pipeline` — l'aperçu n'est jamais branché directement sur la caméra (`AVCaptureVideoPreviewLayer` court-circuiterait le compositing, la caméra virtuelle ne verrait pas les transitions). Toutes les sources sont normalisées à la taille de sortie en BGRA aspect-fill : format de sortie constant, condition nécessaire pour un flux CMIO.

Pendant un gel, un écran d'attente ou un redémarrage de capture, un timer de maintien sert la dernière image (ou l'image d'attente) à ~15 fps — les clients ne voient jamais le « NO SIGNAL » de l'extension pendant la ~1 s de démarrage d'une session.

### Sobriété

- **Un seul rendu GPU par frame**, partagé : Core Image rend dans un `CVPixelBuffer` IOSurface, l'aperçu affiche l'IOSurface directement (`CALayer.contents`) et la caméra virtuelle enfile le même buffer — aucun aller-retour GPU→CPU, aucune copie.
- **Capture YUV natif** (420 bi-planaire) : pas de conversion BGRA dans le stack de capture, ~2,7× moins de bande passante mémoire ; la conversion n'a lieu qu'une fois, dans le rendu Core Image.
- **Capture à la demande** : préréglage juste nécessaire (720p/1080p selon la sortie, VGA pour le PiP), fréquence réglable 30/24/15 ips (PiP plafonné à 15), coupée intégralement quand ni l'aperçu ni un client vidéo ne consomme.
- **Réduction thermique automatique** : si macOS signale une chauffe sérieuse (`ProcessInfo.thermalState`), la capture passe à 15 ips le temps que ça redescende.
- **Zéro polling** : l'extension publie une propriété CMIO custom (`kact`) indiquant si un client lit le flux ; l'app l'écoute en push (`CMIOObjectAddPropertyListenerBlock`, plus un listener sur la liste des devices) et démarre/stoppe la capture toute seule.
- **Extension frugale** : quand l'app alimente le flux, le timer interne de l'extension n'est qu'un chien de garde à 4 Hz ; il ne repasse à 30 fps que pour générer l'image « NO SIGNAL ».

### Caméra virtuelle

`Pipeline.setVirtualSink(_:)` branche le consommateur de `CVPixelBuffer` composés — uniquement quand l'extension est réellement connectée ; sans elle (et aperçu fermé), le rendu est entièrement sauté. `VirtualCameraSink` enfile chaque buffer dans le *stream sink* de l'extension via CoreMediaIO ; l'extension relaie vers son *stream source*, celui que les apps vidéo consomment. Quand l'app n'émet pas, l'extension diffuse une image « NO SIGNAL » animée, générée à la résolution du dernier flux reçu.

## Activer la caméra virtuelle

macOS ne charge une Camera Extension que si elle est signée par un compte Apple Developer **payant** (la capability System Extension n'existe pas sur les comptes gratuits) et si l'app est dans `/Applications` :

1. Build Release signé avec votre équipe :
   ```sh
   xcodebuild -project Cameras.xcodeproj -scheme Cameras -configuration Release \
     -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
   ```
2. Copier `Cameras.app` dans `/Applications` **avec le Finder** (un `cp`/`ditto` ne crée pas la provenance Gatekeeper que `sysextd` exige ; hors Finder l'app peut partir en App Translocation).
3. Purger les enregistrements LaunchServices des copies de build (`lsregister -u <chemin>`) — une copie fantôme dans DerivedData peut faire échouer l'activation.
4. Lancer l'app : l'extension s'active (ou se met à niveau) automatiquement ; autoriser dans Réglages Système › Général › Connexion et extensions.

Vérification : `systemextensionsctl list`.

## Distribution

Pour un autre Mac que celui de développement : export Developer ID + notarisation.

```sh
xcodebuild -project Cameras.xcodeproj -scheme Cameras -configuration Release archive \
  -archivePath build/Cameras.xcarchive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/Cameras.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export -allowProvisioningUpdates
ditto -c -k --keepParent build/export/Cameras.app build/Cameras-notarize.zip
xcrun notarytool submit build/Cameras-notarize.zip --keychain-profile <profil> --wait
xcrun stapler staple build/export/Cameras.app
spctl -a -vv build/export/Cameras.app   # « accepted, source=Notarized Developer ID »
```

`ExportOptions.plist` minimal : `method: developer-id`, `teamID: <votre Team ID>`, `signingStyle: automatic` (non versionné — il contient votre Team ID). Emballer ensuite dans un DMG avec un lien vers `/Applications`.

## Limites connues

- La transition démarre quand la nouvelle session délivre sa première frame (~0,5–1 s de démarrage d'`AVCaptureSession`) ; la dernière image est maintenue entre-temps.
- Sortie 720p ou 1080p (changer la résolution redémarre la session active), 15–30 fps.
- Le PiP maintient une seconde session caméra ouverte en continu (VGA, 15 ips) — seule option à coût énergétique permanent.
- Les raccourcis offrent trois jeux de modificateurs ; les touches elles-mêmes ne sont pas réassignables.
