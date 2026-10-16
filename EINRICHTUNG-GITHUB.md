# Dashboard automatisch bauen und auf dem Smartphone öffnen (GitHub Actions)

GitHub führt `dashboard.R` jeden Morgen aus, verschlüsselt die Seite mit einem Passwort und
veröffentlicht sie unter einer festen Adresse. Dein Rechner muss nicht laufen.

## Einrichtung

1. **Konto und Repository:** Auf github.com ein Konto anlegen und ein neues Repository erstellen,
   z. B. `nachrichten-dashboard`. Es muss *öffentlich* sein: Das kostenlose Konto veröffentlicht
   Pages nur aus öffentlichen Repositories. Der Code und die Quellenliste sind dann sichtbar,
   das Passwort nicht.
2. **Dateien hochladen:** Den Inhalt dieses Ordners ins Repository legen, *einschließlich der
   versteckten Dateien* `.github/workflows/dashboard.yml`, `.staticrypt.json` und `.gitignore`.
   Der Datei-Upload im Browser lässt versteckte Ordner oft aus. Verlässlicher sind GitHub Desktop
   oder `git`. Alternativ legst du die Datei im Browser über *Add file → Create new file* mit dem
   Namen `.github/workflows/dashboard.yml` an und fügst den Inhalt ein.
3. **Passwort festlegen:** Repository → *Settings → Secrets and variables → Actions → New repository
   secret.* Name: `DASHBOARD_PASSWORT`, Wert: dein Passwort.
4. **Pages einschalten:** *Settings → Pages → Build and deployment → Source: GitHub Actions.*
5. **Ersten Lauf starten:** Reiter *Actions* → „Dashboard bauen und verschlüsselt veröffentlichen" →
   *Run workflow.* Der erste Lauf dauert einige Minuten. Im Protokoll siehst du Fehler.
6. **Adresse aufs Handy:** `https://<dein-GitHub-Name>.github.io/<repository>/` im Browser öffnen,
   Passwort eingeben, „Auf diesem Gerät merken" anhaken und die Seite als Lesezeichen oder
   Startbildschirm-Symbol speichern.

## Passwort

Die veröffentlichte Datei ist für jeden herunterladbar. Wer sie hat, kann das Passwort beliebig
oft offline durchprobieren. Der Schutz hängt deshalb allein an der Länge des Passworts: Nimm eine
Passphrase aus vier bis fünf zufälligen Wörtern (mindestens etwa 25 Zeichen), die du nirgends
sonst verwendest. Ändern kannst du es jederzeit im Secret; ab dem nächsten Lauf gilt das neue.

## Betrieb

- **Zeitplan:** täglich 04:15 UTC (06:15 Sommerzeit, 05:15 Winterzeit). Änderbar in der
  Workflow-Datei unter `cron`.
- **Sofort aktualisieren:** *Actions → Run workflow*, auch vom Handy aus im Browser.
- **Ruhemodus:** In öffentlichen Repositories schaltet GitHub geplante Läufe ab, wenn 60 Tage lang nichts
  im Repository passiert ist. Du bekommst eine E-Mail und aktivierst den Zeitplan mit einem Klick wieder.
- **Quellen ändern:** `quellen.yaml` im Repository bearbeiten und speichern. Der nächste Lauf
  übernimmt die Änderung.
- **Gesperrte Quellen:** Manche Medien blockieren Abrufe aus Rechenzentren. Sie erscheinen dann
  unter „Nicht abrufbar" am Seitenende, der Rest läuft weiter.
