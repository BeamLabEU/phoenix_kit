# PR #472 Review — Migrate select elements to daisyUI 5 label wrapper pattern

**Reviewer:** Claude
**Date:** 2026-04-02
**Verdict:** Approve

---

## Summary

Migrates all `<select>` elements across PhoenixKit core modules to the daisyUI 5 label wrapper pattern. In daisyUI 5, selects require a `<label class="select ...">` wrapper around the bare `<select>` element, with styling classes moved from the `<select>` to the `<label>`. This PR applies the pattern consistently across 13 files spanning customer service, DB activity, sitemap, storage, media selector, jobs, settings, organization settings, and the reusable `Select` and `AWSRegionSelect` components.

---

## What Works Well

1. **Consistent pattern application.** Every select follows the same transformation: `<select class="select ...">` becomes `<label class="select ..."><select>...</select></label>`. No select elements were missed or partially converted.

2. **Core component updated.** `select.ex` (the reusable `<.select>` component) was updated, which means any future selects using the component will automatically get the correct daisyUI 5 markup.

3. **AWSRegionSelect component.** The more complex `aws_region_select.ex` with conditional rendering and dynamic classes was correctly migrated, moving the class list to the label wrapper while preserving all conditional styling (`border-success`, `border-error`).

4. **Class preservation.** Sizing classes (`select-sm`, `w-full`, `max-w-xs`), error classes (`select-error`), and focus classes (`focus:select-primary`) are correctly transferred to the `<label>` wrapper.

5. **No functional changes.** All `phx-change`, `phx-target`, `disabled`, `required`, `selected`, and `name` attributes remain on the `<select>` element where they belong. Only presentational classes moved to the wrapper.

---

## Issues and Observations

### Nit: Removed `class` attribute on option in AWSRegionSelect

In `aws_region_select.ex`, the `class="transition-colors duration-150 hover:bg-base-200"` on `<option>` elements was removed. This is correct — `<option>` styling via CSS classes is unreliable cross-browser and these classes likely had no visible effect. Good cleanup.

### Nit: `select-bordered` class removal

Several files had `select-bordered` removed (e.g., in settings selects). In daisyUI 5, the bordered variant is the default for the label wrapper pattern, so this is correct behavior.

---

## Verdict

**Approve.** Mechanical but thorough migration. The pattern is applied consistently across all 13 files with no functional changes. The core `Select` component update ensures future consistency.
