# Nachrichten-Dashboard (R)

    Rscript installieren.R          # einmalig, Pakete installieren
    Rscript dashboard.R --check     # jede Quelle einzeln testen
    Rscript dashboard.R             # Seite bauen (dashboard.html) und im Browser öffnen

Alle Quellen stehen in `quellen.yaml`. Dort legst du auch Reihenfolge, Farben und Mengen fest:

- `layout: bloecke`: jede Quelle ist ein eigener Block, die Blöcke stehen nebeneinander
  (`max_pro_quelle` Meldungen je Block).
- `layout: liste`: eine gemeinsame Liste mit `max_gesamt` Meldungen; je Quelle zählen die
  neuesten, die Quellen wechseln sich ab.
- `farbe`: Identitätsfarbe der Quelle (Kopfband, Rahmen, Rubrik-Marke). Dunkle Töne wählen,
  weil die Schrift im Kopfband weiß ist.
- Pro Feed: Ist die URL kein Feed, sucht das Skript auf der Seite (und eine Ebene tiefer)
  nach Feed-Links. `--check` zeigt bei Fehlern, womit die Antwort beginnt.
  Findet es keinen, liest es mit `href_muster` (regulärer Ausdruck) die Artikel-Links.
  Aus Karten-Layouts nimmt das Skript die erste überschriftartige Textzeile als Titel und erkennt
  Daten wie "14. Okt. 2026" (ohne Uhrzeit). Fehlt ein Datum, stehen die Meldungen in der
  Reihenfolge der Seite. Mit `RB+` gekennzeichnete Rundblick-Artikel erhalten den Hinweis
  "Nur für Abonnenten"; mit `ohne_abo: true` an der Quelle werden sie ganz ausgeblendet.
- `max_pro_quelle` und `max_alter_stunden` gelten global bzw. je Gruppe und lassen sich je Quelle überschreiben.
  `max_alter_stunden: 0` heißt: keine Altersgrenze (nötig für Quellen mit seltenen Meldungen wie die Ministerien).
- Bei den Landesministerien liest das Skript die Presse-Liste des jeweiligen Portals und zeigt nur die
  drei neuesten Meldungen. Jedes Ministerium führt die Liste unter einem eigenen Pfad; `alternativen` nennt
  weitere Pfade, zuletzt die zentrale Liste der Landesregierung. `eigene_domain: true` lässt nur Meldungen
  der eigenen Domain zu. Ist ein `href_muster` gesetzt, weicht das Skript nie auf den allgemeinen RSS-Feed aus.

Für den Abruf vom Smartphone (täglich automatisch gebaut, passwortgeschützt): siehe `EINRICHTUNG-GITHUB.md`.
