export const DashboardContextMenuRemove = {
  mounted() {
    this.el.addEventListener("contextmenu", (e) => {
      e.preventDefault()

      this.pushEvent("remove", {
        id: this.el.dataset.id
      })
    })
  }
}