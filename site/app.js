"use strict";

{
  const data = window.NettworkDemo;
  const $ = (selector, parent = document) => parent.querySelector(selector);
  const $$ = (selector, parent = document) => [...parent.querySelectorAll(selector)];
  const state = {
    selectedId: "sw-ber-04-17",
    mode: "trace",
    reversed: false,
    workStatus: data.workOrder.status,
    toastTimer: 0,
  };

  function icon(name) {
    return `<svg aria-hidden="true"><use href="#${name}"></use></svg>`;
  }
  function object(id) {
    return data.objects[id];
  }
  function announce(message, toast = true) {
    $("#announcer").textContent = message;
    if (!toast) return;
    $("#toast-text").textContent = message;
    $("#toast").classList.add("visible");
    window.clearTimeout(state.toastTimer);
    state.toastTimer = window.setTimeout(() => $("#toast").classList.remove("visible"), 2600);
  }

  function navButton(item, selected = false) {
    return `<button class="nav-row ${selected ? "selected" : ""}" type="button" data-object-id="${item.id}" aria-current="${selected ? "page" : "false"}">${icon(item.icon)}<span class="nav-label">${item.name}</span><span class="nav-meta">${item.kind}</span></button>`;
  }

  function renderNavigation() {
    $("#location-tree").innerHTML = data.locations
      .map(
        ([label, kind], index) =>
          `<button class="nav-row ${index === data.locations.length - 1 ? "selected" : ""}" type="button" data-location="${label}">${icon(index === 0 ? "i-building" : index === 4 ? "i-rack" : "i-info")}<span class="nav-label">${label}</span><span class="nav-meta">${kind}</span></button>`,
      )
      .join("");
    $("#room-objects").innerHTML = data.roomObjects
      .map((id) => navButton(object(id), id === state.selectedId))
      .join("");
    $("#favorites").innerHTML = data.favorites.map((id) => navButton(object(id), id === state.selectedId)).join("");
  }

  function renderInspector() {
    const item = object(state.selectedId);
    $("#inspector-content").innerHTML = `
      <div class="object-head"><div><h2>${item.name}</h2><p>${item.kind}</p></div><span class="badge demo">Mock record</span></div>
      <section class="inspector-section"><dl class="properties">
        <dt>Status</dt><dd><span class="status"><i class="dot"></i>${item.status}</span></dd>
        <dt>VLAN</dt><dd>${item.vlan}</dd><dt>Speed</dt><dd>${item.speed}</dd>
        <dt>Cable</dt><dd><code>${item.cable}</code></dd><dt>Rack</dt><dd>${item.rack}</dd>
        <dt>Location</dt><dd>${item.location}</dd><dt>Last change</dt><dd>${item.lastChange}</dd>
      </dl></section>
      <section class="inspector-section"><h3>Description</h3><p class="note">${item.description}</p></section>
      <section class="inspector-section"><h3>Demo audit note</h3><p class="note">${item.note}<span class="subnote">Representative mock record · no live device or service was queried.</span></p></section>
      <section class="inspector-section"><h3>Demo scope</h3><p class="note"><span class="badge demo">Static GitHub Pages demo</span><br><br>Changes, synchronisation, tracing and work orders simulate local interface state only. They do not contact CloudKit, a camera, a network, or an operational system.</p></section>`;
  }

  function viewTitle(title, copy, badge = '<span class="badge demo">Representative demo</span>') {
    return `<div class="view-title"><div><h2>${title}</h2><p>${copy}</p></div>${badge}</div><p class="demo-callout">All values in this view are representative mock data for the Berlin Campus scenario. This static site has no connection to operational infrastructure, CloudKit, cameras, or live network services.</p>`;
  }

  function selectObject(id, options = {}) {
    if (!object(id)) return;
    state.selectedId = id;
    document.body.classList.remove("sidebar-open");
    $("#sidebar-toggle").setAttribute("aria-expanded", "false");
    renderNavigation();
    renderInspector();
    renderView();
    const item = object(id);
    $("#location-title").textContent = item.name;
    $("#location-path").textContent = item.location.includes("Building")
      ? `Berlin Campus · ${item.location}`
      : `Berlin Campus · Building A · Level 2 · ${item.location}`;
    if (options.focusInspector) $("#inspector").focus?.();
    announce(`${item.name} selected`);
  }

  function traceView() {
    const pathIds = state.reversed
      ? ["sw-ber-04-17", "pp-04-17", "outlet-4b-17", "desk-4b-17"]
      : ["desk-4b-17", "outlet-4b-17", "pp-04-17", "sw-ber-04-17"];
    const path = pathIds
      .map((id, index) => {
        const item = object(id);
        return `<button class="path-node" type="button" data-path-id="${id}" aria-pressed="${id === state.selectedId}"><span class="node-icon">${icon(item.icon)}</span><strong>${item.name}</strong><small>${item.kind}</small></button>${index < pathIds.length - 1 ? '<span class="connector" aria-hidden="true"></span>' : ""}`;
      })
      .join("");
    const events = data.events
      .map(
        (event) =>
          `<article class="event"><span class="event-marker ${event.tone === "info" ? "info" : event.tone === "neutral" ? "neutral" : ""}">${event.tone === "success" ? "✓" : event.tone === "info" ? "i" : "•"}</span><time>${event.time}</time><div class="event-main"><strong>${event.title}</strong><p>${event.detail}</p></div><span class="event-meta">${event.meta}</span></article>`,
      )
      .join("");
    const work = data.workOrder;
    return `${viewTitle("End-to-end path", "A simulated four-hop trace within the representative Berlin Campus dataset.", '<span class="badge ready"><i class="dot"></i>Demo connected</span>')}
      <div class="path-stage"><div class="trace-path" aria-label="Representative connection path">${path}</div><div class="path-summary"><span><i class="dot" style="color:var(--green)"></i>Simulated connected</span><span>28.4 m</span><span>Cat6A U/UTP</span><span>4 hops</span></div></div>
      <section class="section"><div class="section-heading"><div><h3>Event timeline</h3><p>Illustrative events attached to this demo trace.</p></div><button id="show-all-events" class="link-button" type="button">View all</button></div><div class="timeline">${events}</div></section>
      <section class="section"><div class="section-heading"><h3>Related work</h3></div><div class="work-order"><span class="work-icon">${icon("i-work")}</span><div><span class="work-title"><strong>${work.id}</strong><span class="badge progress">${state.workStatus}</span></span><span class="work-desc">${work.title}</span></div><span class="work-meta">Assigned to<b>${work.assignee}</b></span><button id="work-state" class="work-action" type="button">${state.workStatus === "Ready for review" ? "Reopen demo" : "Mark demo ready"}</button></div></section>`;
  }

  function overviewView() {
    return `${viewTitle("Rack overview", "Capacity, operational cues and active mock work for Rack B04.")}
      <div class="cards"><article class="card"><h3>Rack capacity</h3><span class="metric">31 / 42U</span><p>Eleven rack units available in the representative inventory.</p></article><article class="card"><h3>Connected ports</h3><span class="metric">38 / 48</span><p>Counts are a static snapshot, not a switch poll.</p></article><article class="card"><h3>Open work</h3><span class="metric">3</span><p>One in progress, one scheduled and one awaiting review.</p></article></div>
      <section class="section"><div class="section-heading"><div><h3>Attention queue</h3><p>Prioritised representative actions for this rack.</p></div></div><div class="history-list"><article class="history-item"><time>Today · 09:15</time><div><strong>CHG-1842 is in progress</strong><p>Desk relocation is staged in mock work-order state.</p></div><small>Demo work</small></article><article class="history-item"><time>Tomorrow · 10:00</time><div><strong>Uplink label review</strong><p>Representative maintenance reminder for core-sw-01.</p></div><small>Planned</small></article></div></section>`;
  }

  function physicalView() {
    const units = [
      "U42 · Cable manager",
      "U41 · SW-BER-04 48-port access switch",
      "U40 · PP-04 patch panel",
      "U39 · Horizontal cable manager",
      "U38 · Reserved for expansion",
      "U37 · UPS distribution",
    ];
    return `${viewTitle("Physical rack elevation", "A tactile rack-focused view with accessible, representative unit labels.")}
      <div class="rack-elevation"><div class="rack-labels">${["42", "41", "40", "39", "38", "37"].map((n) => `<span>U${n}</span>`).join("")}</div><div class="rack-units">${units.map((label, i) => `<button class="unit ${i === 1 || i === 2 ? "active" : ""}" type="button" data-physical="${i}"><span>${label}</span><span>${i === 4 ? "Reserved" : i === 1 ? "48 ports" : "Ready"}</span></button>`).join("")}</div><div class="rack-key"><strong>Demo elevation</strong><br>Active teal units map to the representative trace path. Selecting a unit explains its mock state through a live announcement.<br><br>No sensor, camera or device inventory is read by this page.</div></div>`;
  }

  function logicalView() {
    return `${viewTitle("Logical relationships", "A simplified relationship view centred on the selected representative object.")}
      <div class="network-map"><div class="network-box"><strong>VLAN 120</strong><small>Users · 10.42.120.0/24</small></div><span class="network-line" aria-hidden="true"></span><div class="network-box"><strong>SW-BER-04</strong><small>Access layer · Gi1/0/17</small></div><span class="network-line" aria-hidden="true"></span><div class="network-box"><strong>core-sw-01</strong><small>Campus core · 100 Gbit/s</small></div></div>
      <section class="section"><div class="section-heading"><div><h3>Relationship facts</h3><p>Static labels that demonstrate contextual network documentation.</p></div></div><div class="cards"><article class="card"><h3>Addressing</h3><p>VRF CORP · 10.42.120.0/24<br>Gateway 10.42.120.1 · .1–.20 reserved</p></article><article class="card"><h3>Selected lease</h3><p>10.42.120.17<br>Representative reservation</p></article><article class="card"><h3>Upstream</h3><p>Po10 · core-sw-01<br>Mock dependency only</p></article></div></section>`;
  }

  function historyView() {
    const entries = [
      ["Today · 09:15", "Work-order note attached", "Representative technician note updated CHG-1842.", "CHG-1842"],
      ["Today · 09:14", "Trace record created", "Static demo trace links Desk 4B-17 to the access port.", "Trace"],
      ["12 Aug · 14:07", "Port label verified", "Illustrative audit of PP-04 / 17 label.", "Audit"],
      ["04 Aug · 10:31", "Rack inventory reconciled", "Mock B04 capacity was refreshed for this demo.", "Inventory"],
    ];
    return `${viewTitle("Object history", "Representative audit and work-order evidence, ordered newest first.")}
      <div class="history-list">${entries.map(([time, title, description, meta]) => `<article class="history-item"><time>${time}</time><div><strong>${title}</strong><p>${description}</p></div><small>${meta}</small></article>`).join("")}</div>
      <section class="section"><div class="section-heading"><div><h3>Audit boundary</h3><p>History is intentionally non-editable in this static demo.</p></div></div><p class="demo-callout">The displayed timeline is part of the bundled mock dataset. It does not represent operational history or synchronised records.</p></section>`;
  }

  function renderView() {
    const views = {
      overview: overviewView,
      physical: physicalView,
      logical: logicalView,
      trace: traceView,
      history: historyView,
    };
    $("#view-panel").innerHTML = views[state.mode]();
    $("#view-panel").setAttribute("aria-labelledby", `tab-${state.mode}`);
    bindViewActions();
  }

  function selectMode(mode, focus = false) {
    if (!["overview", "physical", "logical", "trace", "history"].includes(mode)) return;
    state.mode = mode;
    $$(".tab").forEach((tab) => {
      const active = tab.id === `tab-${mode}`;
      tab.setAttribute("aria-selected", String(active));
      tab.tabIndex = active ? 0 : -1;
    });
    renderView();
    if (focus) $(`#tab-${mode}`).focus();
    announce(`${mode[0].toUpperCase()}${mode.slice(1)} view selected`, false);
  }

  function bindViewActions() {
    $$("[data-path-id]").forEach((button) =>
      button.addEventListener("click", () => selectObject(button.dataset.pathId)),
    );
    $$("#work-state").forEach((button) =>
      button.addEventListener("click", () => {
        state.workStatus = state.workStatus === "Ready for review" ? "In progress" : "Ready for review";
        renderView();
        announce(`Demo work order ${state.workStatus.toLowerCase()}`);
      }),
    );
    $$("#show-all-events").forEach((button) =>
      button.addEventListener("click", () => {
        selectMode("history");
        announce("Showing the representative history view");
      }),
    );
    $$("[data-physical]").forEach((button) =>
      button.addEventListener("click", () => announce(`${button.textContent.trim()} selected in the demo elevation`)),
    );
  }

  function closeSearch() {
    $("#search-results").hidden = true;
  }
  function renderSearch(query) {
    const normalized = query.trim().toLowerCase();
    const results = normalized
      ? Object.values(data.objects).filter((item) =>
          [item.name, item.kind, item.location, item.vlan, item.cable].join(" ").toLowerCase().includes(normalized),
        )
      : [];
    const region = $("#search-results");
    if (!results.length) {
      region.hidden = true;
      return;
    }
    region.innerHTML = results
      .map(
        (item) =>
          `<button class="search-result" type="button" data-search-id="${item.id}">${icon(item.icon)}<span><strong>${item.name}</strong><small>${item.kind} · ${item.location}</small></span></button>`,
      )
      .join("");
    region.hidden = false;
    $$("[data-search-id]", region).forEach((button) =>
      button.addEventListener("click", () => {
        selectObject(button.dataset.searchId);
        $("#global-search").value = "";
        closeSearch();
        $("#workspace").focus();
      }),
    );
  }

  function bindNavigationEvents() {
    document.addEventListener("click", (event) => {
      const objectButton = event.target.closest("[data-object-id]");
      if (objectButton) selectObject(objectButton.dataset.objectId);
      const locationButton = event.target.closest("[data-location]");
      if (locationButton)
        announce(`${locationButton.dataset.location} is part of the representative Berlin Campus location tree.`);
    });
    $("#work-order-nav").addEventListener("click", () => {
      selectMode("overview");
      announce("Showing mock work orders in the overview");
    });
    $$(".tab").forEach((tab) => {
      tab.addEventListener("click", () => selectMode(tab.id.slice(4)));
      tab.addEventListener("keydown", (event) => {
        if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
        event.preventDefault();
        const tabs = $$(".tab");
        const index = tabs.indexOf(tab);
        const next =
          event.key === "Home"
            ? 0
            : event.key === "End"
              ? tabs.length - 1
              : (index + (event.key === "ArrowRight" ? 1 : -1) + tabs.length) % tabs.length;
        selectMode(tabs[next].id.slice(4), true);
      });
    });
  }

  function bindSearchInputEvents() {
    $("#global-search").addEventListener("input", (event) => renderSearch(event.target.value));
    $("#global-search").addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        event.target.value = "";
        closeSearch();
        event.target.blur();
      }
    });
  }

  function bindWorkspaceEvents() {
    $("#sidebar-toggle").addEventListener("click", () => {
      const open = !document.body.classList.contains("sidebar-open");
      document.body.classList.toggle("sidebar-open", open);
      $("#sidebar-toggle").setAttribute("aria-expanded", String(open));
    });
    $("#search-toggle").addEventListener("click", () => {
      document.body.classList.toggle("search-open");
      $("#global-search").focus();
    });
    $("#new-trace").addEventListener("click", () => {
      selectMode("trace");
      selectObject("desk-4b-17");
      announce("New demo trace starts at Desk 4B-17");
    });
    $("#reverse-path").addEventListener("click", () => {
      state.reversed = !state.reversed;
      if (state.mode !== "trace") selectMode("trace");
      else renderView();
      announce(`Demo path direction ${state.reversed ? "reversed" : "restored"}`);
    });
    $("#sync-button").addEventListener("click", () => {
      const button = $("#sync-button");
      button.disabled = true;
      button.classList.add("is-syncing");
      $("#sync-label").textContent = "Demo sync simulating…";
      announce("Demo-only sync simulation started", false);
      window.setTimeout(() => {
        button.disabled = false;
        button.classList.remove("is-syncing");
        $("#sync-label").textContent = "Demo data · synced just now";
        announce("Demo-only sync complete. No data was sent or received.");
      }, 850);
    });
    $("#theme-toggle").addEventListener("click", () => {
      const dark = document.documentElement.dataset.theme !== "dark";
      document.documentElement.dataset.theme = dark ? "dark" : "light";
      $("#theme-toggle").setAttribute("aria-label", `Use ${dark ? "light" : "dark"} theme`);
      announce(`${dark ? "Dark" : "Light"} theme selected`);
    });
  }

  function bindInspectorEvents() {
    $("#mobile-inspector").addEventListener("click", () => {
      document.body.classList.add("inspector-open");
      $("#inspector-toggle").setAttribute("aria-expanded", "true");
    });
    $("#inspector-toggle").addEventListener("click", () => {
      if (matchMedia("(max-width: 790px)").matches) {
        const open = !document.body.classList.contains("inspector-open");
        document.body.classList.toggle("inspector-open", open);
        $("#inspector-toggle").setAttribute("aria-expanded", String(open));
      } else {
        const collapsed = !document.body.classList.contains("inspector-collapsed");
        document.body.classList.toggle("inspector-collapsed", collapsed);
        $("#inspector-toggle").setAttribute("aria-expanded", String(!collapsed));
        announce(`Inspector ${collapsed ? "hidden" : "shown"}`);
      }
    });
  }

  function bindKeyboardEvents() {
    document.addEventListener("keydown", (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        document.body.classList.add("search-open");
        $("#global-search").focus();
      }
      if (event.key === "Escape") {
        document.body.classList.remove("search-open", "inspector-open", "sidebar-open");
        $("#sidebar-toggle").setAttribute("aria-expanded", "false");
        closeSearch();
        $("#global-search").blur();
      }
      if (event.key.toLowerCase() === "i" && !/input|textarea/i.test(document.activeElement.tagName))
        $("#inspector-toggle").click();
    });
  }

  function bindEvents() {
    bindNavigationEvents();
    bindSearchInputEvents();
    bindWorkspaceEvents();
    bindInspectorEvents();
    bindKeyboardEvents();
  }

  renderNavigation();
  renderInspector();
  renderView();
  bindEvents();
}
