#!/bin/bash
# Slug ASCII a partir de texto livre. Acentos são transliterados, não
# descartados: sem isso "mínimo" virava "m-nimo" nos nomes de branch e de
# diretório de ciclo. O `iconv //TRANSLIT` do macOS não serve — produz
# "m'inimo" e "?" para cedilha.
to-slug() {
    python3 -c '
import re, sys, unicodedata
s = unicodedata.normalize("NFD", " ".join(sys.argv[1:]))
s = s.encode("ascii", "ignore").decode().lower()
s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
print(s)
' "$@"
}

if [ "$#" -gt 0 ]; then
    to-slug "$@"
fi
