# PR #357 — Improve entity form UX and clean up data navigator

**Author:** Max Don (mdon)
**Merged into:** dev
**Files changed:** 10 (+333 / -801)

## Summary

- Add "Update Entity" submit button at the top of the entity form for quicker saves
- Move multilang info alert above language tabs and improve its explanation text
- Make slug field translatable and move it into the Entity Information section
- Tighten language tab spacing, replace daisyUI tab classes with compact utility styles
- Add skeleton/ghost loading placeholders for language tab switching on slow connections
- Remove hardcoded category column, filter, and bulk action from data navigator (not all entities have a "category" field)
- Remove entities listing stats/filters and add responsive card view
- Fix credo strict alias ordering

## Changed Files

| File | +/- | Purpose |
|------|-----|---------|
| `entity_form.html.heex` | +176/-113 | Top submit button, translatable slug, skeleton loading, multilang alert, tab styling |
| `entity_form.ex` | +7/-0 | Add `switch_lang_js/1` helper, `JS` alias |
| `entities.html.heex` | +122/-244 | Remove stats/filters, add responsive card view |
| `entities.ex` | +13/-156 | Strip filters/search/stats, `current_base_path` from `url_path` |
| `data_navigator.html.heex` | +4/-90 | Remove category column, filter dropdown, bulk action |
| `data_navigator.ex` | +4/-111 | Remove category assigns, filter, URL param, bulk handler |
| `entity_data.ex` | +0/-82 | Remove `bulk_update_category/2`, `extract_unique_categories/1` |
| `DEEP_DIVE.md` | +5/-3 | Update docs to reflect archive/restore and card view |
| `OVERVIEW.md` | +1/-1 | Update route table description |
| `README.md` | +1/-1 | Update entities.ex description |

## Key Design Decisions

1. **Category removal** — Category was hardcoded as a JSONB field assumption, but dynamic entities don't guarantee a "category" field exists. Correct removal.
2. **Stats removal** — Differentiate entity listing from data navigator; keep stats only where data records are browsed.
3. **Responsive card view** — CSS-based responsive approach: small screens always get card view, toggle only works on md+ screens.
4. **Skeleton loading** — Uses Phoenix LiveView JS commands (`JS.push` + `JS.add_class`/`JS.remove_class`) with dynamic IDs to force morphdom element recreation.
