# Job: slugify

Add `src/slugify.js`, exporting `slugify(input, options)` (CommonJS: `module.exports = { slugify }`).
It turns any title into a URL slug.

## Behaviour
- Lowercase, ASCII letters and digits only. Accented letters lose their accents (`Crème` → `creme`).
- Every run of other characters becomes one hyphen. No hyphen at the start or end.
- An empty result is fine: `slugify("!!!")` is `""`.
- `options.maxLength` (default 60): a longer slug is cut at the last hyphen that keeps it within
  the limit, so words are never split. If the first word alone is too long, cut it at the limit.
  A cut slug never ends with a hyphen.
- Anything that is not a string throws a `TypeError`.

## Out of scope
No dependencies, no CLI, no other files in `src/`.

## Done when
`node --test` passes, including every test in `test/acceptance/` (which must not be edited).
