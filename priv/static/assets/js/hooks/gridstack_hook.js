// assets/js/hooks/gridstack_hook.js

import { GridStack } from "gridstack"
import "gridstack/dist/gridstack.min.css"
import "gridstack/dist/gridstack-extra.min.css" // optional

let GridStackInit = {
  // Called when hook is first mounted
  mounted() {
    console.log("GridStack hook mounted")

    // Initialize GridStack on this element
    this.grid = GridStack.init(
      {
        float: true,
        animate: true,
        disableOneColumnMode: false,
        cellHeight: "auto",
        margin: 10,
        acceptWidgets: ".grid-stack-item"
      },
      this.el  // this.el is the element with phx-hook="GridStackInit"
    )

    // Listen for grid layout changes
    this.grid.on("change", (event, items) => {
      const changes = items.map((item) => ({
        widget_id: item.el?.id || item.id,
        grid_x: item.x,
        grid_y: item.y,
        grid_w: item.w,
        grid_h: item.h
      }))

      // Send changes back to LiveView
      this.pushEvent("gridstack_change", { changes })
    })
  },

  // Called when LiveView receives new data
  updated() {
    if (this.grid) {
      // Refresh grid layout
      this.grid.batchUpdate().commit()
    }
  },

  // Called when hook is destroyed
  destroyed() {
    if (this.grid) {
      this.grid.destroy(false) // false = keep DOM
    }
  },

  // Handle events from LiveView
  handleEvent("widget_added", { widget_id }, socket) {
    // Find new widget element and add to grid
    const el = document.getElementById(widget_id)
    if (el && this.grid) {
      this.grid.addWidget(el)
    }
  },

  handleEvent("widget_removed", { widget_id }, socket) {
    const el = document.getElementById(widget_id)
    if (el && this.grid) {
      this.grid.removeWidget(el, true) // true = remove from DOM
    }
  }
}

export default GridStackInit