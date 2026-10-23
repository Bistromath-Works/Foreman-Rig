// Acceptance tests for SPEC.md. The crew must make these pass and must not edit them.
const test = require("node:test");
const assert = require("node:assert/strict");
const { slugify } = require("../../src/slugify.js");

test("lowercases and joins words with hyphens", () => {
  assert.equal(slugify("Hello World"), "hello-world");
  assert.equal(slugify("Route 66"), "route-66");
});

test("collapses other characters and trims hyphens", () => {
  assert.equal(slugify("  Foreman: the crew!  "), "foreman-the-crew");
  assert.equal(slugify("a---b___c"), "a-b-c");
});

test("strips accents", () => {
  assert.equal(slugify("Crème Brûlée"), "creme-brulee");
});

test("empty results are allowed", () => {
  assert.equal(slugify(""), "");
  assert.equal(slugify("!!!"), "");
});

test("maxLength cuts at a word boundary", () => {
  assert.equal(slugify("the quick brown fox", { maxLength: 10 }), "the-quick");
  assert.equal(slugify("the quick brown fox", { maxLength: 9 }), "the-quick");
  assert.equal(slugify("the quick", { maxLength: 9 }), "the-quick");
});

test("a first word longer than maxLength is cut at the limit", () => {
  assert.equal(slugify("supercalifragilistic word", { maxLength: 5 }), "super");
});

test("defaults to 60 characters and never ends with a hyphen", () => {
  const s = slugify("word ".repeat(30));
  assert.ok(s.length <= 60, `length ${s.length}`);
  assert.ok(!s.endsWith("-"));
  assert.ok(s.startsWith("word-word"));
});

test("rejects non-strings", () => {
  assert.throws(() => slugify(42), TypeError);
  assert.throws(() => slugify(null), TypeError);
});
