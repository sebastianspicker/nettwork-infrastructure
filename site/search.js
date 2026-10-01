"use strict";

window.NettworkSearch = class {
  constructor({ objects, icon, selectObject, announce }) {
    Object.assign(this, { objects, icon, selectObject, announce });
    this.input = document.querySelector("#global-search");
    this.region = document.querySelector("#search-results");
    this.input.addEventListener("input", () => this.render());
    this.input.addEventListener("focus", () => this.render());
    this.input.addEventListener("keydown", (event) => this.inputKeydown(event));
    this.region.addEventListener("keydown", (event) => this.resultKeydown(event));
    for (const eventName of ["pointerdown", "focusin"]) {
      document.addEventListener(eventName, (event) => {
        if (!event.target.closest(".search-region")) this.close();
      });
    }
  }

  close() {
    this.region.hidden = true;
  }

  dismiss() {
    if (matchMedia("(max-width: 790px)").matches) {
      document.body.classList.remove("search-open");
      document.querySelector("#search-toggle").focus();
    } else {
      this.input.focus();
    }
    this.close();
  }

  choose(id) {
    this.selectObject(id);
    this.input.value = "";
    this.close();
    document.body.classList.remove("search-open");
    document.querySelector("#workspace").focus();
  }

  render() {
    const query = this.input.value.trim().toLowerCase();
    this.region.replaceChildren();
    if (!query) {
      this.close();
      return;
    }
    const fields = ["name", "kind", "location", "vlan", "cable", "addresses"];
    const matches = Object.values(this.objects).filter((item) =>
      fields
        .map((field) => item[field] ?? "")
        .join(" ")
        .toLowerCase()
        .includes(query),
    );
    for (const item of matches) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "search-result";
      button.dataset.searchId = item.id;
      button.innerHTML = `${this.icon(item.icon)}<span><strong></strong><small></small></span>`;
      button.querySelector("strong").textContent = item.name;
      button.querySelector("small").textContent = `${item.kind} · ${item.location}`;
      button.addEventListener("click", () => this.choose(item.id));
      this.region.append(button);
    }
    if (!matches.length) {
      const empty = document.createElement("p");
      empty.className = "search-empty";
      empty.textContent = "No demo assets match your search.";
      this.region.append(empty);
    }
    this.region.hidden = false;
    this.announce(
      matches.length ? `${matches.length} demo search results available.` : "No demo assets match your search.",
      false,
    );
  }

  inputKeydown(event) {
    if (event.isComposing) return;
    if (event.key === "Escape") {
      event.stopPropagation();
      this.input.value = "";
      this.dismiss();
      return;
    }
    if (!["ArrowDown", "ArrowUp", "Enter"].includes(event.key)) return;
    if (this.region.hidden) this.render();
    const buttons = this.region.querySelectorAll("button");
    if (!buttons.length) return;
    event.preventDefault();
    if (event.key === "Enter") buttons[0].click();
    else buttons[event.key === "ArrowUp" ? buttons.length - 1 : 0].focus();
  }

  resultKeydown(event) {
    if (event.key === "Escape") {
      event.stopPropagation();
      this.dismiss();
      return;
    }
    if (!["ArrowDown", "ArrowUp"].includes(event.key)) return;
    const buttons = [...this.region.querySelectorAll("button")];
    const index = buttons.indexOf(event.target);
    if (index < 0) return;
    event.preventDefault();
    const step = event.key === "ArrowDown" ? 1 : -1;
    buttons[(index + step + buttons.length) % buttons.length].focus();
  }
};
