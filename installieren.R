# Einmalig ausführen: Rscript installieren.R
pakete <- c("httr", "curl", "xml2", "yaml", "dplyr", "purrr", "htmltools")
fehlend <- setdiff(pakete, rownames(installed.packages()))
if (length(fehlend)) install.packages(fehlend, repos = "https://cloud.r-project.org")
cat("Alle Pakete vorhanden.\n")
