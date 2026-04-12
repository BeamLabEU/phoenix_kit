import { GridStack } from "gridstack"
import "gridstack/dist/gridstack.min.css"

export const Grid = {
  mounted() {
    this.grid = GridStack.init(
      {
        float: true,
        cellHeight: 80,
        draggable: { handle: ".grid-stack-item-content" }
      },
      this.el
    )

    // SAVE LAYOUT
    this.grid.on("change", () => {
      const items = this.grid.engine.nodes.map(n => ({
        uuid: n.el.dataset.uuid,
        x: n.x,
        y: n.y,
        w: n.w,
        h: n.h
      }))

      this.pushEvent("save_grid", { items })
    })

    // -------------------------------------------------------
    // GRIDSTACK OFFICIAL EXTERNAL DRAG SUPPORT
    // -------------------------------------------------------

    const options = {
      appendTo: "body",
      helper: "clone",
      scroll: true
    }

    // enable external drag sources (RIGHT SIDEBAR)
    GridStack.setupDragIn(
      "[data-widget-uuid]",
      options
    )

    // handle DROP INTO GRID
    this.grid.on("dropped", (event, previousWidget, newWidget) => {
      if (!newWidget?.el) return

      const uuid = newWidget.el.dataset.widgetUuid

      const node = newWidget.el.gridstackNode

      this.pushEvent("drop_widget", {
        uuid,
        x: node.x,
        y: node.y,
        w: node.w,
        h: node.h
      })
    })
  }
}