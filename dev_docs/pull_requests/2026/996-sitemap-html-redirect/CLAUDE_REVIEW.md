# PR #996 — Fix /sitemap.html answering 500 on a site mounted at the root

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve, no code changes

Read: `Sitemap.Web.Controller.html/2`, `Routes.path/2` (root-prefix handling, `locale: :none`), the two
route scopes in `integration.ex` (`:416` prefixed, `:1751` root), and the new test.

## Checked and sound

- **Root cause is right.** `"#{prefix}/sitemap.xml"` with prefix `"/"` is `"//sitemap.xml"`, which
  `Phoenix.Controller.redirect/2` refuses as an external-looking target (raises → 500). `Routes.path/2`
  maps a `"/"` prefix to `""` (`routes.ex:1076`), so the root case becomes `/sitemap.xml`.
- **No locale segment.** `locale: :none` keeps `/sitemap.xml` locale-free, which is where both route
  scopes serve it.
- **Test.** Pure conn test, `async: false` (the prefix lives in `:persistent_term`), restores the env and
  clears the cache in `on_exit`; covers `"/"`, `""`, a single and a nested prefix.

No findings.
