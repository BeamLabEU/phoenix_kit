#!/usr/bin/env bash

set -e

echo "🚀 Installing Dashboard System..."

ASSETS_DIR="assets"
HOOKS_DIR="$ASSETS_DIR/js/hooks"
APP_JS="$ASSETS_DIR/js/app.js"

# -------------------------------
# 1. Ensure hooks directory exists
# -------------------------------
mkdir -p "$HOOKS_DIR"

# -------------------------------
# 2. Write Grid hook
# -------------------------------
cat > "$HOOKS_DIR/grid.js" <<'EOF'
import { GridStack } from "gridstack"
import "gridstack/dist/gridstack.min.css"

export const Grid = {
  mounted() {
    this.grid = GridStack.init({
      float: true,
      cellHeight: 80
    }, this.el)

    this.grid.on("change", () => {
      const items = this.grid.engine.nodes.map(n => ({
        id: n.el.dataset.id,
        x: n.x,
        y: n.y,
        w: n.w,
        h: n.h
      }))

      this.pushEvent("save_grid", { items })
    })
  }
}
EOF

# -------------------------------
# 3. Write ContextMenu hook
# -------------------------------
cat > "$HOOKS_DIR/context_menu.js" <<'EOF'
export const ContextMenu = {
  mounted() {
    this.el.addEventListener("contextmenu", (e) => {
      e.preventDefault()

      const id = this.el.dataset.id

      if (confirm("Remove widget?")) {
        this.pushEvent("remove_widget", { id })
      }
    })
  }
}
EOF

# -------------------------------
# 4. Patch app.js (safe append)
# -------------------------------
if ! grep -q "Hooks.Grid" "$APP_JS"; then
  echo "🔧 Patching app.js..."

  cat >> "$APP_JS" <<'EOF'

// ---- Dashboard Hooks ----
import { Grid } from "./hooks/grid"
import { ContextMenu } from "./hooks/context_menu"

let Hooks = window.Hooks || {}
Hooks.Grid = Grid
Hooks.ContextMenu = ContextMenu

export default Hooks
EOF
fi

# -------------------------------
# 5. Install npm packages
# -------------------------------
echo "📦 Installing npm dependencies..."

cd "$ASSETS_DIR"

# ensure package.json exists
if [ ! -f package.json ]; then
  npm init -y
fi

npm install gridstack

cd -

# -------------------------------
# 6. Done
# -------------------------------
echo "✅ Dashboard system installed successfully!"
echo ""
echo "👉 Next steps:"
echo "mix phx.server"