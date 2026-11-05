import { test } from "node:test";
import assert from "node:assert/strict";

import { parseFrontmatter } from "../data.mjs";

test("escalar simples e chave desconhecida", () => {
  const fm = parseFrontmatter("---\nname: foo\nallowed-tools: [a, b]\nmodel: opus\n---\ncorpo");
  assert.equal(fm.name, "foo");
  assert.equal(fm.model, "opus");
});

test(">- junta as linhas e o indicador nao vaza", () => {
  const fm = parseFrontmatter("---\ndescription: >-\n  linha um\n  linha dois\nname: x\n---\n");
  assert.equal(fm.description, "linha um linha dois");
  assert.equal(fm.name, "x");
});

test("| preserva quebras de linha", () => {
  const fm = parseFrontmatter("---\ndescription: |\n  a\n  b\n---\n");
  assert.equal(fm.description, "a\nb");
});

test("aspas com ':' e escapes, e '' em aspas simples", () => {
  const fm = parseFrontmatter("---\ndescription: \"a: b \\\"c\\\"\"\ntitle: 't''s: x'\n---\n");
  assert.equal(fm.description, 'a: b "c"');
  assert.equal(fm.title, "t's: x");
});

test("sem frontmatter devolve objeto vazio", () => {
  assert.deepEqual(parseFrontmatter("# so corpo"), {});
});
