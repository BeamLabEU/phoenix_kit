# PR #440 Review — Fix Permissions Table Style

**PR:** Fix permissions table style
**File:** `lib/phoenix_kit_web/live/users/permissions_matrix.html.heex`
**Stats:** +128 / -135 (net -7 lines)

## Summary

Styling cleanup of the permissions matrix table. Key changes:

1. **Table wrapper**: Replaced `border border-base-300` with `shadow-md`, added `overflow-y-clip` to prevent visual overflow artifacts
2. **Header**: Changed from `bg-base-300 text-base-content` to `bg-primary text-primary-content` — makes the header stand out more with the primary brand color
3. **Zebra striping**: Replaced manual `rem(idx, 2)` alternating background logic with daisyUI's built-in `table-zebra` class — much cleaner
4. **Sticky column backgrounds**: Removed manual background color classes from sticky `<td>` elements (the old code had to duplicate the zebra color on sticky cells to prevent see-through; `table-zebra` + `overflow-y-clip` handles this)
5. **Summary row**: Removed explicit `bg-base-300` background, relying on zebra styling
6. **Unused variable**: `idx` → `_idx` since manual zebra logic was removed

## Assessment

**Approve** — clean, focused styling improvement. The switch to `table-zebra` eliminates ~30 lines of manual alternating-row logic spread across three sections.

## Improvement Suggestions

### 1. Extract the repeated permission cell into a component (medium priority)

The same ~25-line block (Owner badge / read-only icon / toggle button) is copy-pasted **three times** — once for core keys, feature keys, and custom keys. This was true before the PR too, but worth flagging since the file was touched.

A function component would eliminate ~50 lines of duplication:

```heex
<%!-- Define in the LiveView or a shared component module --%>
defp permission_cell(assigns) do
  ~H"""
  <td class="text-center">
    <%= if @role.name == "Owner" do %>
      <span class="badge badge-sm badge-primary badge-outline">{gettext("always")}</span>
    <% else %>
      <%= if MapSet.member?(@uneditable_role_uuids, to_string(@role.uuid)) do %>
        <%= if MapSet.member?(@permissions, @key) do %>
          <.icon name="hero-check-circle" class="w-5 h-5 text-success/50" />
        <% else %>
          <.icon name="hero-x-circle" class="w-5 h-5 text-base-content/10" />
        <% end %>
      <% else %>
        <button phx-click="toggle_permission" phx-value-role_uuid={@role.uuid} phx-value-key={@key}
          class="cursor-pointer hover:opacity-70 transition-opacity">
          <%= if MapSet.member?(@permissions, @key) do %>
            <.icon name="hero-check-circle" class="w-5 h-5 text-success" />
          <% else %>
            <.icon name="hero-x-circle" class="w-5 h-5 text-base-content/20" />
          <% end %>
        </button>
      <% end %>
    <% end %>
  </td>
  """
end
```

Similarly, the entire section loop (header row + permission rows) is repeated three times with only the section label and key list differing. Could be a single helper rendering a section.

### 2. Sticky column background may be transparent with zebra (low priority)

The old code manually set `bg-base-100` / `bg-base-200` on sticky `<td>` cells to prevent see-through when scrolling horizontally. With `table-zebra`, the zebra colors are applied via CSS on `<tr>`, but `sticky` cells with no explicit background may still show content scrolling behind them on some browsers. The `overflow-y-clip` on the wrapper likely mitigates this for vertical overflow, but horizontal scroll see-through on the sticky first column could still occur.

Worth testing with enough roles to trigger horizontal scroll.

### 3. `Enum.with_index` no longer needed (trivial)

Since `_idx` is unused in all three loops after removing manual zebra logic, the `Enum.with_index` calls can be simplified to plain `for key <- @core_keys do` (etc.).

### 4. Header link color contrast (trivial)

The role name links in the header now sit on `bg-primary` with `text-primary-content`. The `link link-hover` class may not have enough contrast on primary backgrounds depending on the theme. Worth a visual check across themes.

## Verdict

Ship it. The zebra simplification is a clear win. The duplication extraction (suggestion #1) and `Enum.with_index` cleanup (#3) would be nice follow-ups but aren't blockers.
