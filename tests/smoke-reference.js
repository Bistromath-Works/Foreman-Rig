// A throwaway build of examples/smoke/SPEC.md. tests/run.sh uses it only to prove the
// example's acceptance tests can pass; it is never copied into a project.
function slugify(input, { maxLength = 60 } = {}) {
  if (typeof input !== "string") throw new TypeError("slugify expects a string");
  const s = input.normalize("NFKD").replace(/[̀-ͯ]/g, "").toLowerCase()
    .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  if (s.length <= maxLength) return s;
  const i = s.slice(0, maxLength + 1).lastIndexOf("-");
  return i > 0 ? s.slice(0, i) : s.slice(0, maxLength);
}
module.exports = { slugify };
