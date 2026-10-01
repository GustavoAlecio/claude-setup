/// Índice da linha que fecha o front-matter; `-1` sem fechamento, `-2` quando [lines] não abre com `---`.
int frontMatterEnd(List<String> lines) {
  if (lines.isEmpty || lines.first.trimRight() != '---') return -2;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].trimRight() == '---') return i;
  }
  return -1;
}
