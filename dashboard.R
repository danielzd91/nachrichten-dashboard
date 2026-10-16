#!/usr/bin/env Rscript
# Lokales Nachrichten-Dashboard: ruft Feeds ab (parallel) und erzeugt dashboard.html
#
# Start:         Rscript dashboard.R
# Nur prüfen:    Rscript dashboard.R --check     (pro Feed OK/FEHLER)
# Ohne Browser:  Rscript dashboard.R --no-open
# Einmalig:      Rscript installieren.R

suppressPackageStartupMessages({
  library(httr); library(curl); library(xml2); library(yaml)
  library(dplyr); library(purrr); library(htmltools)
})

`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1 && is.na(a))) b else a

skript_pfad <- function() {
  arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(arg)) dirname(normalizePath(sub("^--file=", "", arg[1]))) else getwd()
}
BASIS   <- skript_pfad()
AUSGABE <- file.path(BASIS, "dashboard.html")
args    <- commandArgs(trailingOnly = TRUE)
UA      <- "Mozilla/5.0 (lokales Nachrichten-Dashboard)"
TZ      <- tryCatch(Sys.timezone(), error = function(e) NA) %||% "Europe/Berlin"

# --- Einlesen: Feeds und Webseiten ----------------------------------------------
leer <- function() tibble(titel = character(), link = character(),
                          zusammenfassung = character(),
                          zeit = as.POSIXct(character(), tz = "UTC"))

text_bereinigen <- function(s, limit = 240) {
  if (is.null(s) || length(s) == 0 || is.na(s)) return("")
  s <- gsub("<[^>]+>", " ", s)
  s <- gsub("&nbsp;", " ", s, fixed = TRUE)
  s <- trimws(gsub("\\s+", " ", s))
  if (nchar(s) > limit) s <- paste0(sub("\\s+\\S*$", "", substr(s, 1, limit)), " \u2026")
  s
}

# Zeitstempel -> POSIXct (UTC). LC_TIME="C", damit englische Monatsnamen auch auf
# deutschem System erkannt werden.
parse_zeit <- function(x) {
  na <- as.POSIXct(NA, tz = "UTC")
  if (is.null(x) || is.na(x) || !nzchar(trimws(x))) return(na)
  x <- trimws(x)
  alt <- Sys.getlocale("LC_TIME"); on.exit(Sys.setlocale("LC_TIME", alt))
  invisible(Sys.setlocale("LC_TIME", "C"))
  iso <- sub("([+-]\\d{2}):(\\d{2})$", "\\1\\2", sub("Z$", "+0000", x))
  if (grepl("^\\d{4}-", x)) {
    for (f in c("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%OS%z")) {
      t <- suppressWarnings(as.POSIXct(strptime(iso, f, tz = "UTC")))
      if (!is.na(t)) return(t)
    }
    t <- suppressWarnings(as.POSIXct(strptime(substr(x, 1, 19), "%Y-%m-%dT%H:%M:%S", tz = "UTC")))
    return(if (is.na(t)) na else t)
  }
  for (f in c("%a, %d %b %Y %H:%M:%S %z", "%d %b %Y %H:%M:%S %z")) {
    t <- suppressWarnings(as.POSIXct(strptime(x, f, tz = "UTC")))
    if (!is.na(t)) return(t)
  }
  # Zeitzonenkürzel (GMT, CET ...): Kürzel ignorieren, UTC annehmen
  t <- suppressWarnings(as.POSIXct(strptime(sub("\\s+[A-Za-z]{2,4}$", "", x),
                                            "%a, %d %b %Y %H:%M:%S", tz = "UTC")))
  if (is.na(t)) na else t
}

erster_text <- function(knoten, pfad) {
  n <- xml_find_first(knoten, pfad)
  if (inherits(n, "xml_missing")) NA_character_ else xml_text(n)
}

# XML lesen. Bei Syntaxfehlern im Feed: zweiter Versuch mit maskierten "&" (häufigster Fehler),
# dritter Versuch im Reparaturmodus von libxml2.
lese_xml <- function(roh) {
  tryCatch(read_xml(roh), error = function(e1) {
    repariert <- tryCatch(
      charToRaw(gsub("&(?!(?:[A-Za-z][A-Za-z0-9]*|#[0-9]+|#x[0-9A-Fa-f]+);)", "&amp;",
                     rawToChar(roh), perl = TRUE, useBytes = TRUE)),
      error = function(e) roh)
    tryCatch(read_xml(repariert),
      error = function(e2) tryCatch(
        read_xml(repariert, options = c("RECOVER", "NOERROR", "NOWARNING")),
        error = function(e3) stop(conditionMessage(e1), call. = FALSE)))
  })
}

# RSS 2.0, RSS 1.0 (RDF) und Atom
parse_feed <- function(roh) {
  doc <- lese_xml(roh)
  xml_ns_strip(doc)
  items <- xml_find_all(doc, "//item | //entry")
  if (length(items) == 0) stop("keine Eintr\u00e4ge im XML")
  d <- map_dfr(items, function(it) {
    link <- erster_text(it, "./link[not(@href)]")
    if (is.na(link) || !nzchar(trimws(link))) {
      l <- xml_find_first(it, "./link[@rel='alternate' or not(@rel)]/@href")
      link <- if (inherits(l, "xml_missing")) NA_character_ else xml_text(l)
    }
    tibble(
      titel = text_bereinigen(erster_text(it, "./title"), 200),
      link  = trimws(link),
      zusammenfassung = text_bereinigen(erster_text(it, "./description | ./summary")),
      zeit  = parse_zeit(erster_text(it, "./pubDate | ./published | ./updated | ./date"))
    )
  })
  d <- filter(d, nzchar(titel), !is.na(link), nzchar(link))
  if (nrow(d) == 0) stop("keine lesbaren Eintr\u00e4ge im XML")
  d
}

# Fallback ohne Feed: Artikel-Links einer \u00dcbersichtsseite lesen (Reihenfolge der Seite).
# Aus Karten-Layouts (Bild, Rubrik, \u00dcberschrift, Anrei\u00dfer, Datum in einem Link) wird der erste
# \u00dcberschrift-artige Text genommen; ein deutsches Datum ("14. Okt. 2026") wird erkannt.
MONATE_KURZ <- c("jan","feb","m\u00e4r","apr","mai","jun","jul","aug","sep","okt","nov","dez")

datum_aus_text <- function(t) {
  na <- as.POSIXct(NA, tz = "UTC")
  tag <- mon <- jahr <- NA_integer_
  m <- regmatches(t, regexec("(\\d{1,2})\\.(\\d{1,2})\\.(20\\d{2})", t))[[1]]            # 12.10.2026
  if (length(m) == 4) { tag <- as.integer(m[2]); mon <- as.integer(m[3]); jahr <- as.integer(m[4]) }
  else {
    m <- regmatches(t, regexec("(\\d{1,2})\\.\\s*([A-Za-z\u00e4\u00f6\u00fc]+)\\.?\\s+(20\\d{2})", t))[[1]]  # 14. Okt. 2026
    if (length(m) == 4) { tag <- as.integer(m[2]); mon <- match(tolower(substr(m[3], 1, 3)), MONATE_KURZ); jahr <- as.integer(m[4]) }
  }
  if (is.na(tag) || is.na(mon) || is.na(jahr) || mon < 1 || mon > 12 || tag < 1 || tag > 31) return(na)
  lokal <- as.POSIXct(sprintf("%d-%02d-%02d 00:00:00", jahr, mon, tag), tz = TZ)
  as.POSIXct(as.numeric(lokal), origin = "1970-01-01", tz = "UTC")
}

# Die (bis zu vier) Textknoten direkt vor einem Link (au\u00dferhalb anderer Links), n\u00e4chster zuerst: dort steht oft das Datum
vor_texte <- function(a) {
  n <- xml_find_all(a, "preceding::text()[not(ancestor::a)][normalize-space()][position()<=4]")
  rev(trimws(xml_text(n)))      # xml_find_all liefert Dokumentreihenfolge: umdrehen, n\u00e4chster Knoten zuerst
}
zeit_vor <- function(texte) {
  for (t in texte) { z <- datum_aus_text(t); if (!is.na(z)) return(z) }
  as.POSIXct(NA, tz = "UTC")
}

titel_aus_anker <- function(a) {
  tn <- trimws(xml_text(xml_find_all(a, ".//text()")))
  tn <- tn[nzchar(tn)]
  ok <- tn[!grepl("Foto:", tn, fixed = TRUE) & nchar(tn) >= 20 & !grepl("\\d{4}\\s*\u00b7", tn)]
  text_bereinigen(if (length(ok) > 0) ok[1] else xml_text(a), 200)
}

host_von <- function(u) tolower(sub("^www\\.", "", sub("^https?://([^/:?#]+).*$", "\\1", u)))

scrape_seite <- function(html, basis, muster, max_n = 40, host_filter = NA) {
  a <- xml_find_all(html, "//a[@href]")
  if (length(a) == 0) stop("Seite enth\u00e4lt keine Links")
  link <- url_absolute(xml_attr(a, "href"), basis)
  treffer <- grepl(muster, link, perl = TRUE)
  if (!is.na(host_filter)) treffer <- treffer & host_von(link) == host_filter   # nur Links der eigenen Domain
  a <- a[treffer]; link <- link[treffer]
  if (length(a) == 0) stop("Keine Artikel-Links gefunden (href_muster pr\u00fcfen)")
  d <- tibble(link = link, titel = map_chr(a, titel_aus_anker), volltext = map_chr(a, xml_text),
              vor = map(a, vor_texte), idx = seq_along(a))
  d$titel <- sub("\\s+mehr$", "", d$titel)
  # Je Link den inhaltsreichsten Anker nehmen (nicht den reinen Bild-Link), Seitenreihenfolge behalten
  d <- d |> arrange(desc(nchar(volltext))) |> distinct(link, .keep_all = TRUE) |> arrange(idx) |>
    filter(nchar(titel) >= 15, !grepl("^Foto", titel)) |> slice_head(n = max_n)
  if (nrow(d) == 0) stop("Keine Artikel-Links gefunden (href_muster pr\u00fcfen)")
  zeiten <- do.call(c, map(seq_len(nrow(d)), function(i) {
    z <- datum_aus_text(d$volltext[i])
    if (is.na(z)) zeit_vor(d$vor[[i]]) else z
  }))
  tibble(titel = d$titel, link = d$link,
         zusammenfassung = if_else(grepl("RB+", d$volltext, fixed = TRUE), "Nur f\u00fcr Abonnenten (RB+)", ""),
         zeit = as.POSIXct(as.numeric(zeiten), origin = "1970-01-01", tz = "UTC"))
}

# Anfang der Antwort als Text (fuer Fehlermeldungen)
vorschau <- function(roh) tryCatch({
  t <- iconv(rawToChar(roh[seq_len(min(160, length(roh)))]), "UTF-8", "UTF-8", sub = "")
  substr(gsub("\\s+", " ", t), 1, 90)
}, error = function(e) "?")

# Inhalt verarbeiten: Feed -> Feed-Links auf der HTML-Seite (bis zu zwei Ebenen) -> Link-Scraping
lade_inhalt <- function(roh, url, href_muster, timeout, tiefe = 0, host_filter = NA) {
  feed_fehler <- NULL
  d <- tryCatch(parse_feed(roh), error = function(e) { feed_fehler <<- conditionMessage(e); NULL })
  if (!is.null(d)) return(d)
  html <- tryCatch(read_html(roh), error = function(e) NULL)
  if (is.null(html)) stop("Weder Feed noch lesbares HTML (", feed_fehler, ")")

  # Ist ein href_muster angegeben, wird gezielt die Seite ausgelesen (kein Ausweichen auf andere Feeds)
  if (!is.na(href_muster %||% NA)) return(scrape_seite(html, url, href_muster, host_filter = host_filter))

  kandidaten <- character()
  if (tiefe < 2) {
    kandidaten <- c(
      xml_text(xml_find_all(html, "//link[@rel='alternate'][contains(@type,'rss') or contains(@type,'atom')]/@href")),
      xml_text(xml_find_all(html, "//a[contains(@href,'rss') or contains(@href,'RSS') or contains(@href,'/feed') or contains(@title,'RSS')]/@href")))
    kandidaten <- unique(url_absolute(kandidaten[nzchar(kandidaten)], url))
    kandidaten <- head(setdiff(kandidaten, url), 6)
    for (k in kandidaten) {
      d <- tryCatch({
        r <- GET(k, user_agent(UA), timeout(timeout)); stop_for_status(r)
        lade_inhalt(content(r, as = "raw"), k, NA, timeout, tiefe + 1)
      }, error = function(e) NULL)
      if (!is.null(d)) return(d)
    }
  }
  stop(sprintf("Kein Feed erkannt (%s); %d Feed-Link(s) gepr\u00fcft; Antwort beginnt mit: %s",
               feed_fehler %||% "kein XML", length(kandidaten), vorschau(roh)))
}

# Alle Adressen gleichzeitig abrufen
parallel_laden <- function(urls, timeout) {
  pool <- curl::new_pool(host_con = 6, total_con = 24)
  res  <- vector("list", length(urls))
  for (i in seq_along(urls)) local({
    j <- i
    h <- curl::new_handle(timeout = timeout, useragent = UA, followlocation = TRUE)
    curl::curl_fetch_multi(urls[j], pool = pool, handle = h,
      done = function(r) res[[j]] <<- list(ok = TRUE, status = r$status_code, body = r$content),
      fail = function(msg) res[[j]] <<- list(ok = FALSE, msg = msg))
  })
  invisible(curl::multi_run(pool = pool))
  res
}

verarbeite <- function(res, url, href_muster, alt, eigene, timeout) {
  host_filter <- if (isTRUE(eigene)) host_von(url) else NA_character_
  erg <- tryCatch({
    if (!isTRUE(res$ok)) stop(res$msg %||% "keine Antwort")
    if (res$status >= 400) stop(sprintf("HTTP %d", res$status))
    list(daten = lade_inhalt(res$body, url, href_muster, timeout, 0, host_filter), fehler = NA_character_)
  }, error = function(e) list(daten = leer(), fehler = conditionMessage(e)))
  if (is.na(erg$fehler)) return(erg)
  # Alternativen (Pfade oder volle Adressen) der Reihe nach probieren
  for (a in alt) {
    u <- url_absolute(a, url)
    d <- tryCatch({
      r <- GET(u, user_agent(UA), timeout(timeout)); stop_for_status(r)
      lade_inhalt(content(r, as = "raw"), u, href_muster, timeout, 0, host_filter)
    }, error = function(e) NULL)
    if (!is.null(d)) return(list(daten = d, fehler = NA_character_))
  }
  erg
}

# --- Konfiguration -------------------------------------------------------------
feld <- function(x, n, d = NA_character_) { v <- x[[n]]; if (is.null(v)) d else v }
# UTF-8 explizit lesen (Umlaute, Sonderzeichen), unabhängig von der Systemsprache
cfg         <- yaml.load(paste(readLines(file.path(BASIS, "quellen.yaml"), encoding = "UTF-8", warn = FALSE),
                              collapse = "\n"))
max_alter   <- feld(cfg, "max_alter_stunden", 48)
timeout_sek <- feld(cfg, "timeout_sekunden", 12)
PALETTE <- c("#1d4ed8", "#be185d", "#15803d", "#b45309", "#6d3a8c", "#0e7490", "#9f1239", "#475569")

zeilen <- list(); zaehler <- 0
for (gi in seq_along(cfg$gruppen)) for (qi in seq_along(cfg$gruppen[[gi]]$quellen)) {
  zaehler <- zaehler + 1
  q <- cfg$gruppen[[gi]]$quellen[[qi]]
  for (f in q$feeds) zeilen[[length(zeilen) + 1]] <- tibble(
    gi = gi, qi = qi, quelle = q$name, url = f$url,
    rubrik = feld(f, "rubrik", ""), href_muster = feld(f, "href_muster"),
    alt = list(as.character(unlist(f$alternativen))), eigene = isTRUE(f$eigene_domain))
  cfg$gruppen[[gi]]$quellen[[qi]]$farbe <- feld(q, "farbe", PALETTE[(zaehler - 1) %% length(PALETTE) + 1])
}
zeilen <- bind_rows(zeilen)

inhalte    <- parallel_laden(zeilen$url, timeout_sek)
ergebnisse <- pmap(list(inhalte, zeilen$url, zeilen$href_muster, zeilen$alt, zeilen$eigene),
                   function(r, u, m, a, e) verarbeite(r, u, m, a, e, timeout_sek))
zeilen$fehler <- map_chr(ergebnisse, "fehler")
zeilen$n      <- map_int(ergebnisse, \(x) nrow(x$daten))

if ("--check" %in% args) {
  for (i in seq_len(nrow(zeilen))) cat(sprintf("%-6s %-42s %-14s %3d Eintr\u00e4ge  %s\n",
      if (is.na(zeilen$fehler[i])) "OK" else "FEHLER", zeilen$quelle[i], zeilen$rubrik[i],
      zeilen$n[i], if (is.na(zeilen$fehler[i])) "" else zeilen$fehler[i]))
  quit(status = if (any(!is.na(zeilen$fehler))) 1 else 0)
}

# --- Aufbereiten ---------------------------------------------------------------
grenze <- Sys.time() - max_alter * 3600

# Reihum aus mehreren Tabellen je eine Zeile nehmen (erste von A, erste von B, zweite von A ...)
abwechselnd <- function(liste, n = Inf) {
  liste <- keep(liste, \(d) nrow(d) > 0)
  if (length(liste) == 0) return(leer())
  out <- list()
  for (i in seq_len(max(map_int(liste, nrow)))) for (d in liste)
    if (nrow(d) >= i) out[[length(out) + 1]] <- d[i, ]
  bind_rows(out) |> slice_head(n = min(n, length(out)))
}

teile_von <- function(gi, qi, alter_h) {
  idx <- which(zeilen$gi == gi & zeilen$qi == qi)
  map(idx, function(i) {
    d <- ergebnisse[[i]]$daten
    if (!is.na(alter_h) && alter_h > 0)          # 0 = keine Altersgrenze
      d <- filter(d, is.na(zeit) | zeit >= Sys.time() - alter_h * 3600)
    mutate(d, rubrik = zeilen$rubrik[i])
  })
}
alle_fehlgeschlagen <- function(gi, qi) {
  idx <- which(zeilen$gi == gi & zeilen$qi == qi)
  all(!is.na(zeilen$fehler[idx]))
}

gruppen <- map(seq_along(cfg$gruppen), function(gi) {
  g <- cfg$gruppen[[gi]]
  quellen <- map(seq_along(g$quellen), function(qi) {
    q <- g$quellen[[qi]]
    alter_q <- feld(q, "max_alter_stunden", max_alter)
    teile <- teile_von(gi, qi, alter_q)
    d <- if (feld(g, "layout", "bloecke") == "liste") {
      bind_rows(teile) |> distinct(link, .keep_all = TRUE) |> arrange(desc(zeit))   # neueste zuerst
    } else {
      bind_rows(teile) |> distinct(link, .keep_all = TRUE) |>
        filter(!(isTRUE(feld(q, "ohne_abo", FALSE)) & grepl("RB+", zusammenfassung, fixed = TRUE))) |>   # ohne_abo: RB+-Artikel auslassen
        arrange(desc(zeit)) |> slice_head(n = feld(q, "max_pro_quelle", feld(g, "max_pro_quelle", 8)))
    }
    list(name = q$name, farbe = q$farbe, thema = feld(q, "thema", ""), alter = alter_q,
         daten = mutate(d, quelle = q$name, farbe = q$farbe),
         ausgefallen = alle_fehlgeschlagen(gi, qi))
  })
  if (feld(g, "layout", "bloecke") == "liste")
    liste <- abwechselnd(map(quellen, "daten"), feld(g, "max_gesamt", 5))
  else liste <- NULL
  list(titel = g$titel, untertitel = feld(g, "untertitel", ""),
       layout = feld(g, "layout", "bloecke"), quellen = quellen, liste = liste)
})

fehler <- zeilen |> filter(!is.na(fehler)) |>
  transmute(text = paste0(quelle, if_else(nzchar(rubrik), paste0(" (", rubrik, ")"), ""), ": ", fehler))

# --- Darstellung ---------------------------------------------------------------
WOCHENTAGE <- c("Sonntag","Montag","Dienstag","Mittwoch","Donnerstag","Freitag","Samstag")
MONATE <- c("Januar","Februar","M\u00e4rz","April","Mai","Juni","Juli","August","September",
            "Oktober","November","Dezember")
jetzt <- as.POSIXlt(Sys.time(), tz = TZ)
datum_text <- sprintf("%s, %d. %s %d", WOCHENTAGE[jetzt$wday + 1], jetzt$mday,
                      MONATE[jetzt$mon + 1], jetzt$year + 1900)
heute <- as.Date(format(Sys.time(), "%Y-%m-%d", tz = TZ))

zeit_text <- function(z) vapply(seq_along(z), function(i) {
  if (is.na(z[i])) return("")
  tag <- as.Date(format(z[i], "%Y-%m-%d", tz = TZ)); uhr <- format(z[i], "%H:%M", tz = TZ)
  uhr <- if (uhr == "00:00") "" else paste0(" ", uhr)      # Quellen nur mit Datum: ohne Uhrzeit
  if (tag == heute) paste0("heute", uhr)
  else if (tag == heute - 1) paste0("gestern", uhr)
  else paste0(format(z[i], "%d.%m.", tz = TZ), uhr)
}, character(1))

css <- '
:root{--bg:#e8edf2;--fl:#fff;--tx:#14202b;--mut:#566573;--li:#d9e0e7;--ct:var(--c);}
@media (prefers-color-scheme:dark){
 :root{--bg:#0e141a;--fl:#17202a;--tx:#e6ecf1;--mut:#93a3b1;--li:#2a3743;}
 .block,.eintrag{--ct:color-mix(in srgb,var(--c) 42%,#fff);}
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--tx);font:16px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif}
.seite{max-width:1560px;margin:0 auto;padding:0 28px 48px}
.kopf{display:flex;justify-content:space-between;align-items:baseline;flex-wrap:wrap;gap:6px 24px;padding:26px 0 4px}
.kopf h1{margin:0;font-size:1.9rem;font-weight:750;letter-spacing:-.01em}
.kopf .datum{color:var(--mut);font-size:1rem}
.nav{display:flex;gap:18px;flex-wrap:wrap;padding:6px 0 0}
.nav a{color:var(--mut);text-decoration:none;font-weight:600;font-size:.95rem;padding:2px 0;border-bottom:2px solid transparent}
.nav a:hover,.nav a:focus-visible{color:var(--tx);border-bottom-color:var(--tx);outline:none}
.gruppe{margin-top:40px}
.gruppe>h2{margin:0;font-size:1.5rem;font-weight:750}
.gruppe>.unter{margin:2px 0 16px;color:var(--mut);font-size:.95rem}
.raster{display:grid;gap:22px;align-items:start;grid-template-columns:repeat(auto-fit,minmax(340px,1fr))}
.raster.klein{grid-template-columns:repeat(auto-fill,minmax(300px,1fr))}
.block{background:var(--fl);border:2px solid var(--c);border-radius:10px;overflow:hidden}
.block>header{background:var(--c);color:#fff;padding:13px 18px 12px}
.block h3{margin:0;font-size:1.12rem;font-weight:700;line-height:1.25}
.block .thema{margin-top:2px;font-size:.84rem;opacity:.88}
.eintrag{padding:13px 18px 14px;border-top:1px solid var(--li)}
.block>header+.eintrag{border-top:0}
.eintrag a.titel{color:var(--tx);text-decoration:none;font:600 1.03rem/1.35 Charter,"Iowan Old Style",Georgia,serif}
.eintrag a.titel:hover,.eintrag a.titel:focus-visible{text-decoration:underline;text-underline-offset:3px}
.meta{margin-top:5px;color:var(--mut);font-size:.82rem;display:flex;flex-wrap:wrap;gap:4px 10px;align-items:center}
.tag{background:color-mix(in srgb,var(--c) 14%,transparent);color:var(--ct);border-radius:4px;padding:1px 7px;font-weight:600}
.eintrag p{margin:6px 0 0;color:var(--mut);font-size:.9rem}
.leer{margin:0;padding:16px 18px;color:var(--mut);font-size:.9rem}
.liste{max-width:960px;background:var(--fl);border-radius:10px;overflow:hidden;border:1px solid var(--li)}
.liste .eintrag{border-top:1px solid var(--li);border-left:7px solid var(--c);padding-left:16px}
.liste .eintrag:first-child{border-top:0}
.liste .quelle{color:var(--ct);font-weight:700}
.fehler{margin-top:40px;padding:12px 18px;border:1px solid #b45309;border-radius:8px;color:#b45309;font-size:.88rem}
@media (prefers-color-scheme:dark){.fehler{color:#f0b070;border-color:#f0b070}}
.fehler ul{margin:6px 0 0;padding-left:18px}
@media (max-width:560px){.seite{padding:0 14px 40px}.raster,.raster.klein{grid-template-columns:1fr}}'

eintrag_html <- function(titel, link, zusammenfassung, zeit, rubrik, quelle = NULL, zeige_quelle = FALSE, farbe = NULL, ...) {
  z <- zeit_text(zeit)
  meta <- tagList(
    if (zeige_quelle) tags$span(class = "quelle", quelle),
    if (!is.na(rubrik) && nzchar(rubrik)) tags$span(class = "tag", rubrik),
    if (nzchar(z)) tags$span(z))
  tags$article(class = "eintrag", style = if (!is.null(farbe)) paste0("--c:", farbe),
    tags$a(class = "titel", href = link, target = "_blank", rel = "noopener", titel),
    tags$div(class = "meta", meta),
    if (nzchar(zusammenfassung %||% "")) tags$p(zusammenfassung))
}

block_html <- function(q) {
  d <- q$daten
  tags$section(class = "block", style = paste0("--c:", q$farbe),
    tags$header(tags$h3(q$name), if (nzchar(q$thema)) tags$div(class = "thema", q$thema)),
    if (q$ausgefallen) tags$p(class = "leer", "Quelle nicht erreichbar.")
    else if (nrow(d) == 0) tags$p(class = "leer",
      if (!is.na(q$alter) && q$alter > 0) sprintf("Keine Meldungen der letzten %d Stunden.", as.integer(q$alter))
      else "Keine Meldungen gefunden.")
    else pmap(d, \(...) eintrag_html(...)))
}

gruppe_html <- function(g, i) {
  inhalt <- if (g$layout == "liste") {
    d <- g$liste
    tags$div(class = "liste",
      if (nrow(d) == 0) tags$p(class = "leer", "Keine aktuellen Meldungen.")
      else pmap(d, \(...) eintrag_html(..., zeige_quelle = TRUE)))
  } else {
    klein <- length(g$quellen) > 4
    tags$div(class = paste("raster", if (klein) "klein"), map(g$quellen, block_html))
  }
  tags$section(class = "gruppe", id = paste0("g", i), tags$h2(g$titel),
               if (nzchar(g$untertitel)) tags$div(class = "unter", g$untertitel), inhalt)
}

seite <- tags$html(lang = "de",
  tags$head(tags$meta(charset = "utf-8"),
            tags$meta(name = "viewport", content = "width=device-width, initial-scale=1"),
            tags$title("Nachrichten"), tags$style(HTML(css))),
  tags$body(tags$div(class = "seite",
    tags$div(class = "kopf", tags$h1("Nachrichten"),
             tags$span(class = "datum", paste0(datum_text, ", Stand ", format(Sys.time(), "%H:%M", tz = TZ), " Uhr"))),
    tags$nav(class = "nav", map(seq_along(gruppen), \(i) tags$a(href = paste0("#g", i), gruppen[[i]]$titel))),
    map(seq_along(gruppen), \(i) gruppe_html(gruppen[[i]], i)),
    if (nrow(fehler) > 0) tags$div(class = "fehler",
      tags$strong("Nicht abrufbar:"), tags$ul(map(fehler$text, tags$li))))))

save_html(seite, AUSGABE)
cat(sprintf("Dashboard geschrieben: %s  (%d Feed(s) mit Fehler)\n", AUSGABE, nrow(fehler)))
if (!("--no-open" %in% args)) browseURL(paste0("file://", normalizePath(AUSGABE)))
