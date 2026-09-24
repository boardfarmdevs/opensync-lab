// opensync-lab documentation: shared navigation and interactive pieces.
"use strict";
const REPO = "https://github.com/boardfarmdevs/opensync-lab";
const PAGES = [
  ["Start", [["index.html", "Overview"], ["topology.html", "Topology viewer"]]],
  ["Stages", [["build.html", "1 · Build the mv3 image"], ["lab.html", "2 · The lab VM"], ["deploy.html", "3 · Deploy and check"]]],
  ["Inside", [["extender.html", "OpenSync extenders"], ["local-noc.html", "local-noc cloud"]]],
  ["Look up", [["reference.html", "Reference"]]],
];
const LOGO = `<svg width="26" height="26" viewBox="0 0 26 26" aria-hidden="true"><circle cx="13" cy="13" r="5" fill="#37e6b0"/>
<circle cx="13" cy="13" r="10.5" fill="none" stroke="#8aa2ff" stroke-width="1.4" stroke-dasharray="3 3"/>
<circle cx="23.2" cy="10" r="2" fill="#ffb454"/><circle cx="4" cy="17.5" r="2" fill="#8aa2ff"/></svg>`;

function nav() {
  const here = location.pathname.split("/").pop() || "index.html";
  const el = document.createElement("nav");
  el.className = "side";
  el.innerHTML = `<a class="brand" href="index.html">${LOGO}opensync-lab</a>` +
    PAGES.map(([g, items]) => `<div class="grp">${g}</div>` +
      items.map(([h, t]) => `<a class="item${h === here ? " on" : ""}" href="${h}">${t}</a>`).join("")).join("") +
    `<div class="grp">Source</div><a class="item" href="${REPO}">GitHub repository</a>` +
    `<a class="item" href="${REPO}/blob/main/docs/PLAN.md">Implementation plan</a>` +
    `<div class="foot">Generated from the repository by <code>build-docs.sh</code>.</div>`;
  const shell = document.querySelector(".shell");
  shell.prepend(el);
  const b = document.createElement("button");
  b.className = "btn menu"; b.textContent = "☰ Menu"; b.onclick = () => el.classList.toggle("open");
  document.body.prepend(b);
}

function copyButtons(root = document) {
  root.querySelectorAll("pre").forEach(pre => {
    if (pre.querySelector(".copy")) return;
    const b = document.createElement("button");
    b.className = "copy"; b.textContent = "copy";
    b.onclick = () => {
      const text = [...pre.querySelector("code").childNodes].map(n => n.nodeType === 1 && n.classList.contains("c") ? "" : n.textContent).join("");
      navigator.clipboard.writeText(text.replace(/\n{2,}/g, "\n").trim()).then(() => { b.textContent = "copied"; setTimeout(() => b.textContent = "copy", 1200); });
    };
    pre.appendChild(b);
  });
}

const esc = s => String(s == null ? "" : s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
// `code` spans in markdown-ish text from the README tables
const md = s => esc(s).replace(/`([^`]+)`/g, "<code>$1</code>").replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>");
async function json(path) { const r = await fetch(path, { cache: "no-store" }); if (!r.ok) throw new Error(path + " " + r.status); return r.json(); }

// A diagram whose parts carry data-info: hover explains, data-href navigates,
// data-group highlights the related parts.
function diagram(root) {
  const card = root.querySelector(".infocard"), dflt = card ? card.innerHTML : "";
  const parts = root.querySelectorAll("[data-info]");
  parts.forEach(p => {
    p.addEventListener("mouseenter", () => {
      if (card) card.innerHTML = p.dataset.info;
      const g = (p.dataset.group || "").split(" ").filter(Boolean);
      if (g.length) root.querySelectorAll("[data-group]").forEach(q => {
        const qg = q.dataset.group.split(" ");
        q.classList.toggle("dim", !qg.some(x => g.includes(x)));
      });
      p.querySelectorAll(".box").forEach(b => b.classList.add("hl"));
    });
    p.addEventListener("mouseleave", () => {
      if (card) card.innerHTML = dflt;
      root.querySelectorAll(".dim").forEach(q => q.classList.remove("dim"));
      p.querySelectorAll(".box").forEach(b => b.classList.remove("hl"));
    });
    if (p.dataset.href) p.addEventListener("click", () => location.href = p.dataset.href);
  });
}

// Step-through: .stepper buttons, one .step shown at a time; an optional SVG
// whose parts carry data-steps="1 2 5" is highlighted per step.
function stepper(root) {
  const steps = [...root.querySelectorAll(".step")], svg = root.querySelector("svg");
  const bar = root.querySelector(".stepper");
  let i = 0;
  bar.innerHTML = `<button class="nav" data-d="-1">‹ prev</button>` +
    steps.map((_, k) => `<button data-k="${k}">${k + 1}</button>`).join("") + `<button class="nav" data-d="1">next ›</button>`;
  const show = k => {
    i = (k + steps.length) % steps.length;
    steps.forEach((s, n) => s.style.display = n === i ? "" : "none");
    bar.querySelectorAll("[data-k]").forEach(b => b.classList.toggle("on", +b.dataset.k === i));
    if (svg) svg.querySelectorAll("[data-steps]").forEach(p => {
      const on = p.dataset.steps.split(" ").includes(String(i + 1));
      p.classList.toggle("dim", !on);
      p.querySelectorAll(".box").forEach(b => b.classList.toggle("hl", on && p.dataset.focus?.split(" ").includes(String(i + 1))));
    });
  };
  bar.addEventListener("click", e => { const b = e.target.closest("button"); if (!b) return;
    b.dataset.k != null ? show(+b.dataset.k) : show(i + +b.dataset.d); });
  show(0);
}

// A pipeline of buttons each revealing its panel.
function pipeline(root) {
  const btns = [...root.querySelectorAll(".pipeline button")], panels = [...root.querySelectorAll("[data-panel]")];
  const show = k => { btns.forEach(b => b.classList.toggle("on", b.dataset.k === k));
                      panels.forEach(p => p.style.display = p.dataset.panel === k ? "" : "none"); };
  btns.forEach(b => b.onclick = () => show(b.dataset.k));
  show(btns[0].dataset.k);
}

function tabs(root) {
  const btns = [...root.querySelectorAll(".tabs button")], panels = [...root.querySelectorAll("[data-tab]")];
  const show = k => { btns.forEach(b => b.classList.toggle("on", b.dataset.k === k));
                      panels.forEach(p => p.style.display = p.dataset.tab === k ? "" : "none"); };
  btns.forEach(b => b.onclick = () => show(b.dataset.k));
  if (btns.length) show(btns[0].dataset.k);
}

function filterRows(input, table) {
  input.addEventListener("input", () => {
    const q = input.value.toLowerCase();
    table.querySelectorAll("tbody tr").forEach(tr => tr.style.display = tr.textContent.toLowerCase().includes(q) ? "" : "none");
  });
}

document.addEventListener("DOMContentLoaded", () => {
  nav();
  copyButtons();
  document.querySelectorAll(".js-diagram").forEach(diagram);
  document.querySelectorAll(".js-stepper").forEach(stepper);
  document.querySelectorAll(".js-pipeline").forEach(pipeline);
  document.querySelectorAll(".js-tabs").forEach(tabs);
});
