# PR #1068 review

**BUG - MEDIUM** — The board viewer renders a fourth Fresco canvas in the component module. It still emitted inline stage styles under a nonce-based policy. Passed the configured style nonce to that canvas and covered board rendering in the CSP test.

**IMPROVEMENT - MEDIUM** — The image test accepted an empty list of nonced stylesheets. It now requires the actual-size stylesheet to carry the configured style nonce.
