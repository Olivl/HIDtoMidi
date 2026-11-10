# HIDtoMidi

Utilitaire macOS (13 Ventura et plus, **Intel et Apple Silicon**) qui transforme les touches d'**un clavier précis** (par exemple un clavier Bluetooth) en **Note, Control Change ou Program Change**.

## Application (recommandé)

`HIDtoMidi.app` est un binaire universel : le même `.app` tourne sur un Mac Intel sous Ventura et sur un Mac M1/M2 sous Sequoia.

### Installer sur un Mac

1. Télécharger la dernière release disponible, la décompresser et mettre `HIDtoMidi.app` dans `/Applications`.
2. L'app n'est pas signée par un développeur Apple, donc macOS la bloque au premier lancement :
   - **Ventura** : clic droit sur l'app → Ouvrir → Ouvrir.
   - **Sequoia** : lancez-la une fois (elle est bloquée), puis allez dans Réglages Système → Confidentialité et sécurité → en bas, « Ouvrir quand même ».
   - Dans tous les cas, si macOS dit qu'elle est « endommagée » : `xattr -dr com.apple.quarantine /Applications/HIDtoMidi.app`
3. Autoriser HIDtoMidi dans **Réglages Système → Confidentialité et sécurité → Surveillance de l'entrée** (puis relancer l'app), et dans **Accessibilité** pour le mode exclusif.
   *(Chaque nouvelle version change la signature : il faudra peut-être retirer l'ancienne entrée et autoriser de nouveau.)*

### Utilisation

1. **Périphérique** : choisir l'appareil dans la liste déroulante. Seules ses touches sont converties. L'app le retrouve tout seul quand il se reconnecte.
2. **Mode exclusif** (activé par défaut) : les touches de ce périphérique ne tapent plus rien dans les autres applications. Le clavier intégré du Mac n'est jamais capturé.
   macOS réserve la capture directe d'un clavier aux programmes lancés en root. HIDtoMidi bloque donc les frappes de ce périphérique avec un filtre, ce qui demande une autorisation de plus : **Réglages Système → Confidentialité et sécurité → Accessibilité**. Un bandeau orange l'indique. 
3. **Capturer** : cliquer, puis appuyer sur une touche du périphérique choisi. Une ligne est créée pour cette touche. Le bouton clavier de chaque ligne réattribue une touche. *Échap* annule.
4. Pour chaque touche, choisir :
   - le **message** : Note, Control Change, Program Change, Program +1 ou Program −1 ;
   - le **canal**, le **n°** (note, CC ou programme), la **valeur** (vélocité ou valeur CC) et la valeur **Off** du CC ;
   - le **mode** : *Maintenu* (on à l'appui, off au relâchement), *Bascule* (un appui = on, l'appui suivant = off) ou *Impulsion* (à l'appui seulement).
5. Dans le logiciel à commander (DAW, QLab…), choisir l'entrée MIDI **HIDtoMidi**. Vous pouvez aussi envoyer directement vers une sortie existante (bus IAC, interface USB).

Une touche peut avoir plusieurs lignes, par exemple un PC et un CC à la fois. Pendant le jeu, la ligne de la touche enfoncée s'allume. 

**Panic** coupe toutes les notes. 
**Importer / Exporter** sert à passer la configuration d'un Mac à l'autre. Les réglages sont enregistrés automatiquement.

> Les noms de touches correspondent à la position sur un clavier QWERTY : sur un clavier AZERTY, la touche « A » s'affiche « Q ». Ça ne gêne pas : la détection par appui attribue toujours la bonne touche.

### Compiler (sur n'importe quel Mac, Apple Silicon compris)

```bash
./build-app.sh          # → build/HIDtoMidi.app et build/HIDtoMidi.zip
```

Il faut seulement les outils en ligne de commande (`xcode-select --install`). Xcode n'est pas nécessaire.
