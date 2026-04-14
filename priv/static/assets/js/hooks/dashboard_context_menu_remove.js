export const DashboardContextMenuRemove = {
  mounted() {
    this.el.addEventListener("contextmenu", (e) => {
      e.preventDefault()

    const id = this.el.dataset.uuid
    this.pushEvent("remove_widget", { uuid: id })
    })
  }
}