import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// The visual workflow builder, in the spirit of
// Make.com: modules are round bubbles on a dotted canvas, joined left to
// right; filters sit on the links; a router fans out into routes; a repeat
// loop wraps its steps; cleanup ("finally") is its own lane underneath.
//
// One controller, three modes:
//   edit — click a bubble to edit it in the side panel, "+" to add modules,
//          the toolbar to save, undo, zoom, edit settings or the raw JSON.
//          The definition lives in the form's hidden textarea (source).
//   view — the same canvas, read-only (the workflow page).
//   run  — read-only with each step's status; a bubble opens its step.
//
// Everything it offers (modules, fields, data, operators, gates) comes from
// Harbor::Workflows::Catalog, passed in as JSON, so the server stays the
// source of truth and validation still happens on save. Nothing here knows a
// step type or a trigger by name beyond the three the engine walks itself
// (choice, loop, filter) and the agent types' warnings.

const COL = 144          // width of a module cell
const NODE_H = 146       // height of a module cell (bubble + two lines)
const SPINE = 44         // y of the bubble's centre inside a cell
const D = 76             // bubble diameter
const GAP = 22           // space between cells on a path

const ICONS = {
  github: '<circle cx="18" cy="18" r="3"/><circle cx="6" cy="6" r="3"/><path d="M13 6h3a2 2 0 0 1 2 2v7"/><path d="M6 9v12"/>',
  at: '<circle cx="12" cy="12" r="4"/><path d="M16 8v5a3 3 0 0 0 6 0v-1a10 10 0 1 0-4 8"/>',
  play: '<polygon points="7 4 19 12 7 20 7 4"/>',
  calendar: '<rect x="3" y="4" width="18" height="18" rx="2"/><path d="M16 2v4M8 2v4M3 10h18"/>',
  bot: '<path d="M12 8V4H8"/><rect width="16" height="12" x="4" y="8" rx="2"/><path d="M2 14h2M20 14h2M15 13v2M9 13v2"/>',
  shield: '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="m9 12 2 2 4-4"/>',
  message: '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>',
  eye: '<path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/>',
  user: '<path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/>',
  tag: '<path d="M12 2H2v10l9.29 9.29a1 1 0 0 0 1.41 0l8.59-8.59a1 1 0 0 0 0-1.41Z"/><circle cx="7" cy="7" r="1.5"/>',
  bell: '<path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>',
  funnel: '<polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3"/>',
  router: '<circle cx="5" cy="12" r="2.5"/><path d="M7.5 12H11M11 12c3 0 3-6 6-6h3M11 12c3 0 3 6 6 6h3"/>',
  repeat: '<path d="m17 2 4 4-4 4"/><path d="M3 11v-1a4 4 0 0 1 4-4h14"/><path d="m7 22-4-4 4-4"/><path d="M21 13v1a4 4 0 0 1-4 4H3"/>',
  clock: '<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>',
  hand: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="m16 11 2 2 4-4"/>',
  workflow: '<rect x="3" y="3" width="8" height="8" rx="2"/><path d="M7 11v4a2 2 0 0 0 2 2h4"/><rect x="13" y="13" width="8" height="8" rx="2"/>',
  box: '<path d="M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16Z"/><path d="m3.3 7 8.7 5 8.7-5M12 22V12"/>',
  trash: '<path d="M3 6h18M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  minus: '<path d="M5 12h14"/>',
  flag: '<path d="M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z"/><path d="M4 22v-7"/>',
  sliders: '<path d="M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6"/>',
  braces: '<path d="M8 3H7a2 2 0 0 0-2 2v5a2 2 0 0 1-2 2 2 2 0 0 1 2 2v5a2 2 0 0 0 2 2h1M16 21h1a2 2 0 0 0 2-2v-5a2 2 0 0 1 2-2 2 2 0 0 1-2-2V5a2 2 0 0 0-2-2h-1"/>',
  undo: '<path d="M3 7v6h6"/><path d="M21 17a9 9 0 0 0-15-6.7L3 13"/>',
  redo: '<path d="M21 7v6h-6"/><path d="M3 17a9 9 0 0 1 15-6.7L21 13"/>',
  fit: '<path d="M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7"/>',
  help: '<circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3M12 17h.01"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
  x: '<path d="M18 6 6 18M6 6l12 12"/>',
  alert: '<path d="M12 9v4M12 17h.01"/>',
  pause: '<path d="M10 4v16M14 4v16"/>',
  skip: '<path d="M5 12h14"/>',
  copy: '<rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
  left: '<path d="m15 18-6-6 6-6"/>',
  right: '<path d="m9 18 6-6-6-6"/>',
  up: '<path d="m18 15-6-6-6 6"/>',
  down: '<path d="m6 9 6 6 6-6"/>'
}

const icon = (name, size = 20, stroke = 2) =>
  `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="${stroke}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONS[name] || (String(name ?? "").includes("<") ? name : ICONS.help)}</svg>`

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c])
const clone = (o) => (o === undefined ? undefined : JSON.parse(JSON.stringify(o)))
const slug = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "").replace(/^(\d)/, "s_$1") || "step"
const samePath = (a, b) => a && b && a.length === b.length && a.every((v, i) => v === b[i])

const STATUS = {
  ok: { icon: "check", cls: "is-ok", label: "done" },
  error: { icon: "x", cls: "is-error", label: "failed" },
  canceled: { icon: "x", cls: "is-error", label: "canceled" },
  running: { icon: "pause", cls: "is-running", label: "running" },
  waiting: { icon: "clock", cls: "is-waiting", label: "waiting" },
  skipped: { icon: "skip", cls: "is-skipped", label: "skipped" }
}

export default class extends Controller {
  static targets = ["source", "viewport", "stage", "panel", "picker", "zoomLabel", "details", "warnings"]
  static values = {
    catalog: Object,
    mode: { type: String, default: "edit" },
    definition: Object,
    statuses: Object,
    errors: Array,
    // Run pages: the step whose details the server-rendered panel is showing.
    selectedKey: String
  }

  // ── lifecycle ────────────────────────────────────────────────────────
  connect() {
    this.def = this.readDefinition()
    this.history = [JSON.stringify(this.def)]
    this.future = []
    this.scale = 1
    this.tx = 24
    this.ty = 24
    this.selected = null
    this.dirty = false
    this.modules = this.catalogValue.modules || []
    this.bindViewport()
    if (this.hasPanelTarget) {
      this.panelTarget.addEventListener("focusin", (e) => {
        const el = e.target
        if (el.matches("[data-template]")) this.lastField = { el, kind: "template" }
        else if (el.matches("[data-cond-path]")) this.lastField = { el, kind: "path" }
      })
    }
    // A refresh redraws the canvas. When it opened or closed the details panel
    // on a run page, the graph is fitted again into what is left uncovered;
    // otherwise the position and zoom you chose stay.
    this.hadRunPanel = !!this.runPanel()
    this.onMorph = () => {
      this.render()
      const has = !!this.runPanel()
      if (has !== this.hadRunPanel) { this.hadRunPanel = has; this.fit({ initial: true }) }
    }
    this.onKey = (e) => this.key(e)
    this.onUnload = (e) => { if (this.dirty) { e.preventDefault(); e.returnValue = "" } }
    document.addEventListener("turbo:morph", this.onMorph)
    if (this.editing) {
      document.addEventListener("keydown", this.onKey)
      window.addEventListener("beforeunload", this.onUnload)
      this.element.addEventListener("submit", () => { this.dirty = false })
    }
    this.render()
    this.fit({ initial: true })
  }

  disconnect() {
    document.removeEventListener("turbo:morph", this.onMorph)
    document.removeEventListener("keydown", this.onKey)
    window.removeEventListener("beforeunload", this.onUnload)
  }

  get editing() { return this.modeValue === "edit" }

  readDefinition() {
    let def
    if (this.hasSourceTarget) {
      try { def = JSON.parse(this.sourceTarget.value || "{}") } catch { def = {} ; this.parseFailed = true }
    } else {
      def = clone(this.definitionValue) || {}
    }
    def.triggers = Array.isArray(def.triggers) ? def.triggers : []
    def.steps = Array.isArray(def.steps) ? def.steps : []
    def.finally = Array.isArray(def.finally) ? def.finally : []
    def.settings = def.settings && typeof def.settings === "object" ? def.settings : {}
    return def
  }

  // ── model helpers ────────────────────────────────────────────────────
  get(path) { return path.reduce((o, k) => (o == null ? undefined : o[k]), this.def) }

  moduleFor(step) {
    return this.modules.find((m) => m.type === step.type && (!m.action || m.action === step.action)) ||
      { type: step.type, label: step.type, icon: "help", color: "#94A3B8", fields: [], outputs: [] }
  }

  triggerFor(t) {
    return (this.catalogValue.triggers || []).find((k) => k.kind === t.kind) ||
      { kind: t.kind, label: t.kind, icon: "help", color: "#94A3B8", fields: [] }
  }

  // Every step in run order, with its path: main, then cleanup.
  allSteps() {
    const out = []
    const walk = (list, path) => list.forEach((s, i) => {
      const p = [...path, i]
      out.push({ step: s, path: p })
      if (s.type === "choice") {
        ;(s.branches || []).forEach((b, bi) => walk(b.steps || [], [...p, "branches", bi, "steps"]))
        walk(s.otherwise || [], [...p, "otherwise"])
      } else if (s.type === "loop") {
        walk(s.steps || [], [...p, "steps"])
      }
    })
    walk(this.def.steps, ["steps"])
    walk(this.def.finally, ["finally"])
    return out
  }

  uniqueKey(base) {
    const keys = new Set(this.allSteps().map((s) => s.step.key))
    let key = slug(base)
    let n = 2
    while (keys.has(key)) key = `${slug(base)}_${n++}`
    return key
  }

  commit({ panel = false } = {}) {
    const json = JSON.stringify(this.def)
    if (json !== this.history[this.history.length - 1]) {
      this.history.push(json)
      if (this.history.length > 100) this.history.shift()
      this.future = []
      this.dirty = true
    }
    if (this.hasSourceTarget) this.sourceTarget.value = JSON.stringify(this.def, null, 2)
    this.render()
    if (panel) this.renderPanel()
  }

  undo() {
    if (this.history.length < 2) return
    this.future.push(this.history.pop())
    this.restore(this.history[this.history.length - 1])
  }

  redo() {
    const next = this.future.pop()
    if (!next) return
    this.history.push(next)
    this.restore(next)
  }

  restore(json) {
    this.def = JSON.parse(json)
    if (this.hasSourceTarget) this.sourceTarget.value = JSON.stringify(this.def, null, 2)
    this.dirty = true
    if (this.selected && this.selected.kind !== "settings" && this.selected.kind !== "json" &&
        this.selected.kind !== "help" && this.get(this.selected.path) === undefined) this.selected = null
    this.render()
    this.renderPanel()
  }

  // What still needs filling in, per step key (shown as a ! on the bubble).
  problems(step) {
    const mod = this.moduleFor(step)
    const missing = (mod.fields || []).filter((f) => f.required && this.isEmpty(step[f.name])).map((f) => f.label)
    if (step.type === "agent" || step.type === "verifier") {
      if (this.isEmpty(step.prompt) && this.isEmpty(step.slash_command)) missing.push("a prompt or slash command")
    }
    if (step.type === "choice") {
      ;(step.branches || []).forEach((b, i) => { if (this.condEmpty(b.when)) missing.push(`route ${i + 1}'s filter`) })
    }
    if (step.type === "filter" && this.condEmpty(step.when)) missing.push("its condition")
    return missing
  }

  isEmpty(v) {
    return v === undefined || v === null || v === "" || (Array.isArray(v) && v.length === 0) ||
      (typeof v === "object" && !Array.isArray(v) && Object.keys(v).length === 0)
  }

  condEmpty(c) {
    if (!c) return true
    if (c.all || c.any) return (c.all || c.any).every((x) => this.condEmpty(x))
    if (c.not) return this.condEmpty(c.not)
    return !c.path
  }

  serverErrorsFor(key) {
    return (this.errorsValue || []).filter((e) => e.startsWith(`${key}:`) || e.startsWith(`${key} `))
  }

  // ── layout ───────────────────────────────────────────────────────────
  // A block is laid out in its own coordinates: width, height, the y of
  // its spine (where the path runs), entry and exit points, and the things
  // to draw. Sequences put blocks side by side on a shared spine.
  block(w, h, spine) {
    return { w, h, spine, entry: { x: 0, y: spine }, exit: { x: w, y: spine }, nodes: [], edges: [], boxes: [], badges: [], marks: [] }
  }

  place(into, b, dx, dy) {
    const pt = (p) => ({ ...p, x: p.x + dx, y: p.y + dy })
    b.nodes.forEach((n) => into.nodes.push(pt(n)))
    b.edges.forEach((e) => into.edges.push({ ...e, from: pt(e.from), to: pt(e.to), via: e.via && e.via.map(pt) }))
    b.boxes.forEach((r) => into.boxes.push(pt(r)))
    b.badges.forEach((r) => into.badges.push(pt(r)))
    b.marks.forEach((r) => into.marks.push(pt(r)))
  }

  layoutSeq(list, path, { lane } = {}) {
    const items = list.map((step, i) => this.layoutStep(step, [...path, i]))
    if (this.editing) items.push(this.layoutGhost(path, list.length))
    if (items.length === 0) items.push(this.layoutEmpty())
    const spine = Math.max(...items.map((b) => b.spine))
    const out = this.block(0, 0, spine)
    let x = 0
    let prev = null
    items.forEach((b, i) => {
      const dy = spine - b.spine
      this.place(out, b, x, dy)
      const entry = { x: x + b.entry.x, y: dy + b.entry.y }
      if (prev) {
        const insertAt = b.ghost ? null : i
        out.edges.push({ from: prev, to: entry, insert: insertAt === null ? null : { path, index: insertAt }, target: b.firstKey, lane })
      } else {
        out.entry = entry
      }
      prev = { x: x + b.exit.x, y: dy + b.exit.y }
      out.h = Math.max(out.h, dy + b.h)
      x += b.w + GAP
    })
    out.w = x - GAP
    out.exit = prev
    out.firstKey = items[0].firstKey
    return out
  }

  layoutStep(step, path) {
    if (step.type === "choice") return this.layoutRouter(step, path)
    if (step.type === "loop") return this.layoutLoop(step, path)
    if (step.type === "filter") return this.layoutFilter(step, path)
    const b = this.block(COL, NODE_H, SPINE)
    b.nodes.push({ x: COL / 2, y: SPINE, kind: "step", path, step })
    b.entry = { x: COL / 2 - D / 2, y: SPINE }
    b.exit = { x: COL / 2 + D / 2, y: SPINE }
    b.firstKey = step.key
    return b
  }

  // A filter is drawn on the link, the way Make draws one: a small funnel
  // in the line, with its condition underneath.
  layoutFilter(step, path) {
    const w = 120
    const b = this.block(w, NODE_H, SPINE)
    b.badges.push({ x: w / 2, y: SPINE, kind: "filter", path, step, label: step.name, cond: step.when })
    b.entry = { x: w / 2 - 17, y: SPINE }
    b.exit = { x: w / 2 + 17, y: SPINE }
    b.firstKey = step.key
    return b
  }

  layoutGhost(path, index) {
    const b = this.block(64, NODE_H, SPINE)
    b.marks.push({ x: 32, y: SPINE, kind: "ghost", path, index })
    b.entry = { x: 32 - 20, y: SPINE }
    b.exit = { x: 32 + 20, y: SPINE }
    b.ghost = true
    return b
  }

  layoutEmpty() {
    const b = this.block(24, 60, 30)
    b.marks.push({ x: 12, y: 30, kind: "dot" })
    b.entry = { x: 8, y: 30 }
    b.exit = { x: 16, y: 30 }
    return b
  }

  layoutRouter(step, path) {
    const RD = 58
    const head = 112                 // the router bubble's cell
    const fan = 104                  // room for the curve and the route filter
    const routes = (step.branches || []).map((br, i) => ({
      seq: this.layoutSeq(br.steps || [], [...path, "branches", i, "steps"]),
      badge: { kind: "route", path: [...path, "branches", i], label: br.name || `Route ${i + 1}`, cond: br.when, index: i }
    }))
    const fallback = this.layoutSeq(step.otherwise || [], [...path, "otherwise"])
    routes.push({ seq: fallback, badge: { kind: "fallback", path, label: "Fallback", fallback: true } })

    let y = 0
    const stacked = routes.map((r) => {
      const top = y
      y += r.seq.h + 18
      return { ...r, top, spine: top + r.seq.spine }
    })
    const total = y - 18
    const spine = (stacked[0].spine + stacked[stacked.length - 1].spine) / 2
    const widest = Math.max(...stacked.map((r) => r.seq.w))
    const mergeX = head + fan + widest + 26
    const b = this.block(mergeX + 12, Math.max(total, NODE_H), spine)
    b.nodes.push({ x: head / 2, y: spine, kind: "router", path, step, d: RD })
    b.entry = { x: head / 2 - RD / 2, y: spine }
    stacked.forEach((r) => {
      const ox = head + fan
      this.place(b, r.seq, ox, r.top)
      const start = { x: head / 2 + RD / 2, y: spine }
      const badgeAt = { x: head + fan - 52, y: r.spine }
      const entry = { x: ox + r.seq.entry.x, y: r.top + r.seq.entry.y }
      b.edges.push({ from: start, to: { x: badgeAt.x - 15, y: badgeAt.y }, curve: true, target: r.seq.firstKey, route: r.badge })
      b.edges.push({ from: { x: badgeAt.x + 15, y: badgeAt.y }, to: entry, target: r.seq.firstKey, route: r.badge,
        insert: this.editing ? { path: r.badge.fallback ? [...path, "otherwise"] : [...r.badge.path, "steps"], index: 0 } : null })
      b.badges.push({ ...r.badge, x: badgeAt.x, y: badgeAt.y })
      const exit = { x: ox + r.seq.exit.x, y: r.top + r.seq.exit.y }
      b.edges.push({ from: exit, to: { x: mergeX, y: spine }, curve: true, route: r.badge, join: true })
    })
    b.marks.push({ x: mergeX, y: spine, kind: "join" })
    b.exit = { x: mergeX + 6, y: spine }
    b.firstKey = step.key
    return b
  }

  layoutLoop(step, path) {
    const LD = 64
    const head = 120
    const top = 34
    const pad = 18
    const body = this.layoutSeq(step.steps || [], [...path, "steps"])
    const spine = top + body.spine
    const w = head + body.w + pad * 2
    const h = top + body.h + 26
    const b = this.block(w + 14, h, spine)
    b.boxes.push({ x: 0, y: 0, w, h, kind: "loop", path, step })
    b.nodes.push({ x: head / 2, y: spine, kind: "loop", path, step, d: LD })
    this.place(b, body, head + pad, top)
    b.edges.push({ from: { x: head / 2 + LD / 2, y: spine }, to: { x: head + pad + body.entry.x, y: top + body.entry.y },
      target: body.firstKey, insert: this.editing ? { path: [...path, "steps"], index: 0 } : null })
    // The way back round: from the end of the body, under it, to the loop.
    const end = { x: head + pad + body.exit.x, y: top + body.exit.y }
    b.edges.push({ from: end, to: { x: head / 2, y: spine + LD / 2 + 58 }, back: true, bottom: h - 10, loopKey: step.key })
    b.entry = { x: head / 2 - LD / 2, y: spine }
    b.exit = { x: w, y: spine }
    b.edges.push({ from: { x: end.x, y: spine }, to: { x: w, y: spine }, target: null, exitLink: true })
    b.firstKey = step.key
    return b
  }

  layoutAll() {
    const all = this.block(0, 0, 0)
    // Triggers, stacked, all leading into the first step.
    const triggers = this.def.triggers.map((t, i) => ({ t, i }))
    // Triggers centre on the path; "Add trigger" hangs underneath them.
    const tCount = Math.max(1, triggers.length)
    const main = this.layoutSeq(this.def.steps, ["steps"])
    const spine = Math.max(main.spine, (tCount - 1) * NODE_H / 2 + SPINE)
    const tTop = spine - SPINE - ((tCount - 1) * NODE_H) / 2
    const mainX = COL + 150
    // Each trigger has its filter on its own link; the links join, then
    // lead into the first step.
    const joinAt = { x: mainX - 40, y: spine }
    triggers.forEach(({ t, i }) => {
      const y = tTop + i * NODE_H + SPINE
      all.nodes.push({ x: COL / 2, y, kind: "trigger", path: ["triggers", i], trigger: t })
      const badge = { x: COL / 2 + D / 2 + 44, y }
      if (!this.editing && this.condEmpty(t.conditions)) {
        all.edges.push({ from: { x: COL / 2 + D / 2, y }, to: joinAt, curve: true, trigger: true, target: main.firstKey })
        return
      }
      all.edges.push({ from: { x: COL / 2 + D / 2, y }, to: { x: badge.x - 15, y }, trigger: true, target: main.firstKey })
      all.edges.push({ from: { x: badge.x + 15, y }, to: joinAt, curve: true, trigger: true, target: main.firstKey })
      all.badges.push({ x: badge.x, y, kind: "trigger-filter", path: ["triggers", i], cond: t.conditions, label: "Trigger filter" })
    })
    if (triggers.length) {
      if (triggers.length > 1) all.marks.push({ ...joinAt, kind: "join" })
      all.edges.push({ from: joinAt, to: { x: mainX + main.entry.x, y: spine - main.spine + main.entry.y }, target: main.firstKey,
        insert: this.editing ? { path: ["steps"], index: 0 } : null })
    }
    if (this.editing) {
      const y = triggers.length ? tTop + (triggers.length - 1) * NODE_H + SPINE + 112 : spine
      all.marks.push({ x: COL / 2, y, kind: "add-trigger" })
    }
    this.place(all, main, mainX, spine - main.spine)
    let height = Math.max(spine - main.spine + main.h, tTop + tCount * NODE_H + (this.editing ? 40 : 0))
    let width = mainX + main.w

    // Cleanup lane.
    if (this.editing || this.def.finally.length) {
      const laneTop = height + 56
      const fin = this.layoutSeq(this.def.finally, ["finally"], { lane: "finally" })
      const fSpine = laneTop + Math.max(SPINE, fin.spine)
      all.marks.push({ x: COL / 2, y: fSpine, kind: "cleanup", top: laneTop - 28 })
      all.edges.push({ from: { x: COL / 2 + 30, y: fSpine }, to: { x: mainX + fin.entry.x, y: fSpine - fin.spine + fin.entry.y }, target: fin.firstKey,
        lane: "finally", insert: this.editing ? { path: ["finally"], index: 0 } : null })
      this.place(all, fin, mainX, fSpine - fin.spine)
      all.lane = { y: laneTop - 30 }
      height = Math.max(height, fSpine - fin.spine + fin.h)
      width = Math.max(width, mainX + fin.w)
    }
    all.w = width + 40
    all.h = height + 20
    return all
  }

  // ── rendering ────────────────────────────────────────────────────────
  render() {
    if (!this.hasStageTarget) return
    if (!this.editing) this.def = this.readDefinitionForView()
    const L = this.layoutAll()
    this.layout = L
    const statuses = this.statusesValue || {}
    const parts = []
    parts.push(`<svg class="wf-edges" width="${L.w}" height="${L.h}" aria-hidden="true">`)
    parts.push('<defs><marker id="wf-arrow" viewBox="0 0 10 10" refX="5" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="#86C49A"/></marker></defs>')
    L.boxes.forEach((r) => parts.push(`<rect x="${r.x}" y="${r.y}" width="${r.w}" height="${r.h}" rx="28" class="wf-loopbox"/>`))
    if (L.lane) parts.push(`<line x1="0" x2="${L.w}" y1="${L.lane.y}" y2="${L.lane.y}" class="wf-lane"/>`)
    L.edges.forEach((e) => parts.push(this.edgeSvg(e, statuses)))
    parts.push("</svg>")

    L.boxes.forEach((r) => parts.push(this.loopLabel(r, statuses)))
    L.edges.forEach((e) => {
      if (!this.editing || !e.insert) return
      const mx = (e.from.x + e.to.x) / 2
      const my = (e.from.y + e.to.y) / 2
      parts.push(`<button type="button" class="wf-insert" style="left:${mx}px;top:${my}px" data-action="harbor--workflow-builder#openPicker"
        data-path='${JSON.stringify(e.insert.path)}' data-index="${e.insert.index}" title="Add a module here" aria-label="Add a module here">${icon("plus", 14, 2.5)}</button>`)
    })
    L.marks.forEach((m) => parts.push(this.markHtml(m)))
    L.badges.forEach((bd) => parts.push(this.badgeHtml(bd, statuses)))
    L.nodes.forEach((n) => parts.push(this.nodeHtml(n, statuses)))
    this.stageTarget.innerHTML = parts.join("")
    this.stageTarget.style.width = `${L.w}px`
    this.stageTarget.style.height = `${L.h}px`
    this.applyTransform()
    this.renderWarnings()
  }

  readDefinitionForView() {
    const def = clone(this.definitionValue) || {}
    def.triggers = def.triggers || []
    def.steps = def.steps || []
    def.finally = def.finally || []
    def.settings = def.settings || {}
    return def
  }

  edgeSvg(e, statuses) {
    const { from: a, to: b } = e
    let d
    if (e.back) {
      d = `M ${a.x} ${a.y} C ${a.x + 40} ${a.y}, ${a.x + 40} ${e.bottom}, ${a.x - 20} ${e.bottom} L ${b.x + 20} ${e.bottom} C ${b.x - 10} ${e.bottom}, ${b.x} ${e.bottom - 10}, ${b.x} ${b.y}`
    } else if (Math.abs(a.y - b.y) < 1) {
      d = `M ${a.x} ${a.y} L ${b.x} ${b.y}`
    } else {
      const dx = Math.max(30, (b.x - a.x) / 2)
      d = `M ${a.x} ${a.y} C ${a.x + dx} ${a.y}, ${b.x - dx} ${b.y}, ${b.x} ${b.y}`
    }
    let cls = "wf-edge"
    if (this.modeValue === "run") {
      const taken = e.back ? (statuses[e.loopKey]?.iterations > 1) : this.edgeTaken(e, statuses)
      cls += taken ? " is-taken" : " is-idle"
    }
    if (e.back) cls += " is-back"
    return `<path d="${d}" class="${cls}"${e.back ? ' marker-end="url(#wf-arrow)"' : ""}/>`
  }

  edgeTaken(e, statuses) {
    if (e.route) {
      const router = this.get(e.route.path.slice(0, e.route.fallback ? e.route.path.length : -2))
      const st = router && statuses[router.key]
      if (!st || st.branch === undefined) return false
      const label = e.route.fallback ? "otherwise" : (e.route.label)
      return st.branch === label || (!e.route.fallback && st.index === e.route.index)
    }
    if (e.target) return !!statuses[e.target]
    return false
  }

  nodeHtml(n, statuses) {
    if (n.kind === "trigger") return this.triggerNodeHtml(n)
    const step = n.step
    const mod = this.moduleFor(step)
    const d = n.d || D
    const st = statuses[step.key]
    const selected = (this.selected && this.selected.kind === "step" && samePath(this.selected.path, n.path)) ||
      (this.modeValue === "run" && !this.selected && this.selectedKeyValue && this.selectedKeyValue === step.key)
    const problems = this.editing ? this.problems(step) : []
    const serverErrors = this.serverErrorsFor(step.key)
    const classes = ["wf-node"]
    if (selected) classes.push("is-selected")
    if (this.modeValue === "run") classes.push(st ? STATUS[st.status]?.cls || "" : "is-unreached")
    if (serverErrors.length) classes.push("has-error")
    const sub = n.kind === "router" ? `Router · ${(step.branches || []).length} route${(step.branches || []).length === 1 ? "" : "s"}`
      : n.kind === "loop" ? `Repeat ≤ ${step.max_iterations || "?"}×` : mod.label
    let badge = ""
    if (st && STATUS[st.status]) badge = `<span class="wf-status ${STATUS[st.status].cls}" title="${STATUS[st.status].label}">${icon(STATUS[st.status].icon, 12, 3)}</span>`
    else if (problems.length || serverErrors.length) badge = `<span class="wf-status is-warn" title="${esc([...serverErrors, ...problems.map((p) => `needs ${p}`)].join("; "))}">${icon("alert", 12, 3)}</span>`
    const count = st && st.count > 1 ? `<span class="wf-count">×${st.count}</span>` : ""
    const extra = st ? [st.verdict, st.branch && `→ ${st.branch}`, st.result && `${st.result}${st.iterations ? ` after ${st.iterations}` : ""}`, st.decision].filter(Boolean).join(" · ") : ""
    const label = `${step.name || step.key}, ${sub}${st ? `, ${STATUS[st.status]?.label || st.status}` : ""}${problems.length ? ", needs setting up" : ""}`
    return `<button type="button" class="${classes.join(" ")}" style="left:${n.x - COL / 2}px;top:${n.y - d / 2}px;--d:${d}px"
        data-action="harbor--workflow-builder#selectNode" data-kind="step" data-path='${JSON.stringify(n.path)}' aria-label="${esc(label)}">
      <span class="wf-bubble" style="--c:${mod.color}">${icon(mod.icon, Math.round(d * 0.4), 1.9)}${badge}${count}</span>
      <span class="wf-title">${esc(step.name || step.key)}</span>
      <span class="wf-sub">${esc(sub)}</span>
      ${extra ? `<span class="wf-extra">${esc(extra)}</span>` : ""}
    </button>`
  }

  // A step later steps can run in: its type was registered as one that
  // makes a workspace.
  makesWorkspace(step) { return this.modules.some((m) => m.makes_workspace && m.type === step.type) }

  triggerNodeHtml(n) {
    const t = n.trigger
    const kind = this.triggerFor(t)
    const selected = this.selected && this.selected.kind === "trigger" && samePath(this.selected.path, n.path)
    // What a trigger says under its bubble: the fields its kind names, or the
    // kind's own label.
    const sub = kind.summary_fields
      ? kind.summary_fields.map((f) => (Array.isArray(t[f]) ? t[f].join(" | ") : t[f])).filter(Boolean).join(" · ") || kind.summary_empty || kind.label
      : kind.label
    return `<button type="button" class="wf-node is-trigger${selected ? " is-selected" : ""}" style="left:${n.x - COL / 2}px;top:${n.y - D / 2}px;--d:${D}px"
        data-action="harbor--workflow-builder#selectNode" data-kind="trigger" data-path='${JSON.stringify(n.path)}' aria-label="Trigger: ${esc(kind.label)}, ${esc(sub)}">
      <span class="wf-bubble" style="--c:${kind.color}">${icon(kind.icon, 30, 1.9)}<span class="wf-bolt" aria-hidden="true">⚡</span></span>
      <span class="wf-title">${esc(kind.label)}</span>
      <span class="wf-sub">${esc(sub)}</span>
    </button>`
  }

  badgeHtml(bd, statuses) {
    const active = bd.kind === "fallback" ? true : !this.condEmpty(bd.cond)
    if (bd.kind === "trigger-filter" && !active && !this.editing) return ""
    const selected = this.selected && ((this.selected.kind === "route" && bd.kind === "route" && samePath(this.selected.path, bd.path)) ||
      (this.selected.kind === "step" && bd.kind === "filter" && samePath(this.selected.path, bd.path)) ||
      (this.selected.kind === "fallback" && bd.kind === "fallback" && samePath(this.selected.path, bd.path)) ||
      (this.selected.kind === "trigger" && bd.kind === "trigger-filter" && samePath(this.selected.path, bd.path)))
    const kindAttr = bd.kind === "filter" ? "step" : bd.kind === "trigger-filter" ? "trigger" : bd.kind
    const text = bd.kind === "fallback" ? "Fallback: no route matched" : this.describe(bd.cond)
    let cls = `wf-filter${active ? " is-set" : ""}${selected ? " is-selected" : ""}${bd.kind === "fallback" ? " is-fallback" : ""}`
    if (this.modeValue === "run" && bd.kind === "filter") {
      const st = statuses[bd.step.key]
      if (st) cls += st.passed === false ? " is-blocked" : " is-passed"
      else cls += " is-unreached"
    }
    const caption = bd.kind === "trigger-filter" ? "" : `<span class="wf-filter-label">${esc(bd.label || "")}</span>`
    const offset = 0
    const tip = `${bd.label ? `${bd.label}: ` : ""}${text}`
    return `<button type="button" class="${cls}" style="left:${bd.x}px;top:${bd.y + offset}px" data-action="harbor--workflow-builder#selectNode"
        data-kind="${kindAttr}" data-path='${JSON.stringify(bd.path)}' title="${esc(tip)}" aria-label="${esc(tip)}">
      ${icon(bd.kind === "fallback" ? "right" : "funnel", 14, 2.2)}${caption}
      ${active && bd.kind !== "fallback" && bd.kind !== "trigger-filter" ? `<span class="wf-filter-cond">${esc(this.shortDescribe(bd.cond))}</span>` : ""}
    </button>`
  }

  loopLabel(r, statuses) {
    const step = r.step
    const st = statuses[step.key]
    const until = step.until && !this.condEmpty(step.until) ? ` until ${this.shortDescribe(step.until)}` : ""
    return `<div class="wf-looplabel" style="left:${r.x + 20}px;top:${r.y + 8}px">${icon("repeat", 12, 2.4)} Repeat up to ${esc(step.max_iterations || "?")}×${esc(until)}${st?.result ? ` · <b>${esc(st.result)}</b>` : ""}</div>`
  }

  markHtml(m) {
    switch (m.kind) {
      case "ghost":
        return `<button type="button" class="wf-ghost" style="left:${m.x}px;top:${m.y}px" data-action="harbor--workflow-builder#openPicker"
          data-path='${JSON.stringify(m.path)}' data-index="${m.index}" title="Add a module" aria-label="Add a module">${icon("plus", 18, 2.5)}</button>`
      case "add-trigger":
        return `<button type="button" class="wf-ghost is-trigger" style="left:${m.x}px;top:${m.y}px" data-action="harbor--workflow-builder#openTriggerPicker"
          title="Add a trigger" aria-label="Add a trigger">${icon("plus", 18, 2.5)}<span>Add trigger</span></button>`
      case "join":
        return `<span class="wf-join" style="left:${m.x}px;top:${m.y}px" aria-hidden="true"></span>`
      case "dot":
        return `<span class="wf-dot" style="left:${m.x}px;top:${m.y}px" aria-hidden="true"></span>`
      case "cleanup":
        return `<div class="wf-cleanup" style="left:${m.x}px;top:${m.y}px"><span class="wf-cleanup-bubble">${icon("flag", 22, 2)}</span>
          <span class="wf-title">Cleanup</span><span class="wf-sub">always runs at the end</span></div>
          <div class="wf-lanelabel" style="top:${m.top}px">Cleanup · runs however the main path ended</div>`
      default:
        return ""
    }
  }

  describe(c) {
    if (!c || this.condEmpty(c)) return "always"
    if (c.all) return c.all.map((x) => this.describe(x)).join(" and ")
    if (c.any) return `(${c.any.map((x) => this.describe(x)).join(" or ")})`
    if (c.not) return `not ${this.describe(c.not)}`
    const op = (this.catalogValue.operators || []).find((o) => o.op === c.op)
    const v = Array.isArray(c.values) ? c.values.join(", ") : (c.value ?? "")
    return [c.path, op ? op.label : c.op, op && op.arity === 0 ? "" : v].filter((x) => x !== "").join(" ")
  }

  // "review_state is one of changes_requested…" — the last part of each
  // path, for the caption under a filter on the canvas.
  shortDescribe(c) {
    const short = (x) => {
      if (!x) return ""
      if (x.all) return x.all.map(short).join(" & ")
      if (x.any) return x.any.map(short).join(" or ")
      if (x.not) return `not ${short(x.not)}`
      const op = (this.catalogValue.operators || []).find((o) => o.op === x.op)
      const v = Array.isArray(x.values) ? x.values.join(", ") : (x.value ?? "")
      const field = String(x.path || "").split(".").slice(-1)[0]
      return [field, op ? op.label : x.op, op && op.arity === 0 ? "" : v].filter((y) => y !== "").join(" ")
    }
    const text = short(c)
    return text.length > 48 ? `${text.slice(0, 46)}…` : text
  }

  renderWarnings() {
    if (!this.hasWarningsTarget || !this.editing) return
    const keys = new Map()
    this.allSteps().forEach(({ step }) => keys.set(step.key, (keys.get(step.key) || 0) + 1))
    const dupes = [...keys].filter(([, n]) => n > 1).map(([k]) => k)
    const unset = this.allSteps().filter(({ step }) => this.problems(step).length).length
    const msgs = []
    if (this.parseFailed) msgs.push("The saved JSON couldn't be read, so the canvas started empty. Open {} to see it.")
    if (!this.def.triggers.length) msgs.push("Add a trigger: nothing starts this workflow yet.")
    if (dupes.length) msgs.push(`Two steps share the key ${dupes.join(", ")}.`)
    if (unset) msgs.push(`${unset} module${unset === 1 ? "" : "s"} still need${unset === 1 ? "s" : ""} setting up (marked !).`)
    this.warningsTarget.textContent = msgs.join(" ")
    this.warningsTarget.hidden = msgs.length === 0
  }

  // ── pan & zoom ───────────────────────────────────────────────────────
  bindViewport() {
    if (!this.hasViewportTarget) return
    const vp = this.viewportTarget
    let drag = null
    vp.addEventListener("pointerdown", (e) => {
      if (e.button !== 0 || e.target.closest("button, a, input, select, textarea, .wf-picker")) return
      drag = { x: e.clientX, y: e.clientY, tx: this.tx, ty: this.ty, moved: false }
      vp.setPointerCapture(e.pointerId)
    })
    vp.addEventListener("pointermove", (e) => {
      if (!drag) return
      const dx = e.clientX - drag.x
      const dy = e.clientY - drag.y
      if (Math.abs(dx) + Math.abs(dy) > 3) drag.moved = true
      this.tx = drag.tx + dx
      this.ty = drag.ty + dy
      this.applyTransform()
    })
    const end = (e) => {
      if (drag && !drag.moved && this.editing && !e.target.closest("button")) this.closePanel()
      drag = null
    }
    vp.addEventListener("pointerup", end)
    vp.addEventListener("pointercancel", () => { drag = null })
    vp.addEventListener("wheel", (e) => {
      if (e.ctrlKey || e.metaKey) {
        e.preventDefault()
        const rect = vp.getBoundingClientRect()
        this.zoomAt(this.scale * (e.deltaY < 0 ? 1.1 : 1 / 1.1), e.clientX - rect.left, e.clientY - rect.top)
      } else if (this.editing || e.shiftKey) {
        e.preventDefault()
        this.tx -= e.deltaX
        this.ty -= e.deltaY
        this.applyTransform()
      }
    }, { passive: false })
  }

  applyTransform() {
    if (!this.hasStageTarget) return
    this.stageTarget.style.transform = `translate(${this.tx}px, ${this.ty}px) scale(${this.scale})`
    if (this.hasZoomLabelTarget) this.zoomLabelTarget.textContent = `${Math.round(this.scale * 100)}%`
  }

  zoomAt(scale, cx, cy) {
    const s = Math.min(1.6, Math.max(0.35, scale))
    this.tx = cx - ((cx - this.tx) * s) / this.scale
    this.ty = cy - ((cy - this.ty) * s) / this.scale
    this.scale = s
    this.applyTransform()
  }

  zoomIn() { const r = this.viewportTarget.getBoundingClientRect(); this.zoomAt(this.scale * 1.15, r.width / 2, r.height / 2) }
  zoomOut() { const r = this.viewportTarget.getBoundingClientRect(); this.zoomAt(this.scale / 1.15, r.width / 2, r.height / 2) }

  fit({ initial = false } = {}) {
    if (!this.hasViewportTarget || !this.layout) return
    const vp = this.viewportTarget
    const pw = vp.clientWidth - this.coveredWidth() - 48
    const ph = vp.clientHeight - 96
    // Opening a workflow keeps the text readable (pan for the rest);
    // the Fit button shows the whole thing however small.
    let s = Math.min(1, pw / this.layout.w, ph / this.layout.h)
    s = Math.max(initial ? 0.8 : 0.35, s)
    this.scale = s
    this.tx = 24 + Math.max(0, (pw - this.layout.w * s) / 2)
    this.ty = Math.max(24, (ph - this.layout.h * s) / 2 + 24)
    this.applyTransform()
  }

  // How much of the canvas a panel is covering on the right: the builder's
  // own, or on a run page the details panel the server rendered.
  coveredWidth() {
    if (this.panelOpen && this.hasPanelTarget && !this.panelTarget.hidden) return this.panelTarget.offsetWidth || 400
    const runPanel = this.runPanel()
    if (runPanel) return runPanel.offsetWidth
    return this.panelOpen ? 400 : 0
  }

  runPanel() { return this.modeValue === "run" ? this.element.querySelector(".wf-run-panel") : null }

  // ── selection & panel ────────────────────────────────────────────────
  selectNode(e) {
    const el = e.currentTarget
    const kind = el.dataset.kind
    const path = JSON.parse(el.dataset.path)
    if (this.modeValue === "run" && kind === "step") {
      const st = (this.statusesValue || {})[this.get(path)?.key]
      if (st?.url) {
        // Same page, another step: a replace visit morphs, so the canvas keeps
        // its position and zoom and only the details panel changes.
        this.selected = null
        this.renderPanel()
        Turbo.visit(st.url.split("#")[0], { action: "replace" })
        return
      }
    }
    this.selected = { kind, path }
    this.closePicker()
    this.render()
    this.renderPanel()
    this.keepVisible(el)
  }

  // Slide the canvas so the thing being edited isn't under the panel.
  keepVisible(el) {
    if (!this.hasViewportTarget || !this.panelOpen) return
    const vp = this.viewportTarget.getBoundingClientRect()
    const target = this.stageTarget.querySelector(`[data-kind="${el.dataset.kind}"][data-path='${el.dataset.path}']`) || el
    const r = target.getBoundingClientRect()
    const room = vp.right - (this.panelTarget.hidden ? 0 : this.panelTarget.offsetWidth) - 40
    if (r.right > room) this.tx -= r.right - room
    if (r.left < vp.left + 40) this.tx += vp.left + 40 - r.left
    this.applyTransform()
  }

  closePanel() {
    if (!this.selected) return
    this.selected = null
    this.render()
    this.renderPanel()
  }

  openSettings() { this.selected = { kind: "settings" }; this.closePicker(); this.render(); this.renderPanel() }
  openJson() { this.selected = { kind: "json" }; this.closePicker(); this.render(); this.renderPanel() }
  openHelp() { this.selected = { kind: "help" }; this.closePicker(); this.render(); this.renderPanel() }

  get panelOpen() { return !!this.selected }

  renderPanel() {
    if (!this.hasPanelTarget) return
    const p = this.panelTarget
    if (this.hasDetailsTarget && p.contains(this.detailsTarget)) {
      this.detailsTarget.hidden = true
      this.element.appendChild(this.detailsTarget)
    }
    if (!this.selected) { p.hidden = true; p.innerHTML = ""; return }
    p.hidden = false
    this.lastField = null
    const sel = this.selected
    let html = ""
    if (sel.kind === "step") html = this.stepPanel(sel.path)
    else if (sel.kind === "trigger") html = this.triggerPanel(sel.path)
    else if (sel.kind === "route") html = this.routePanel(sel.path)
    else if (sel.kind === "fallback") html = this.fallbackPanel(sel.path)
    else if (sel.kind === "settings") html = this.settingsPanel()
    else if (sel.kind === "json") html = this.jsonPanel()
    else if (sel.kind === "help") html = this.helpPanel()
    p.innerHTML = `<div class="wf-panel-inner">${html}</div>`
    if (sel.kind === "settings" && this.hasDetailsTarget) {
      p.querySelector("[data-details-slot]")?.appendChild(this.detailsTarget)
      this.detailsTarget.hidden = false
    }
    this.wirePanel(p)
  }

  panelHead(color, iconName, title, sub, { remove = false, extra = "" } = {}) {
    return `<div class="wf-panel-head">
      <span class="wf-panel-bubble" style="--c:${color}">${icon(iconName, 20, 2)}</span>
      <div class="min-w-0 flex-1"><h2 class="wf-panel-title">${esc(title)}</h2>${sub ? `<p class="wf-panel-sub">${esc(sub)}</p>` : ""}</div>
      ${extra}
      <button type="button" class="wf-iconbtn" data-action="harbor--workflow-builder#closePanel" aria-label="Close">${icon("x", 18)}</button>
    </div>`
  }

  stepPanel(path) {
    const step = this.get(path)
    if (!step) return ""
    const mod = this.moduleFor(step)
    const ro = !this.editing
    const fields = []
    fields.push(this.field({ name: "name", label: "Name", kind: "text" }, step.name, ro, path))
    fields.push(this.field({ name: "key", label: "Key", kind: "text", help: "Later steps read this step as steps.<key>." }, step.key, ro, path, { mono: true }))
    ;(mod.fields || []).forEach((f) => fields.push(this.field(f, step[f.name], ro, path, { step })))
    let routes = ""
    if (step.type === "choice") {
      routes = `<div class="wf-section"><h3>Routes</h3><ol class="wf-routes">${(step.branches || []).map((b, i) =>
        `<li><button type="button" class="wf-link" data-action="harbor--workflow-builder#selectNode" data-kind="route" data-path='${JSON.stringify([...path, "branches", i])}'>
          ${icon("funnel", 13)} ${esc(b.name || `Route ${i + 1}`)}</button><span class="wf-hint">${esc(this.describe(b.when))}</span></li>`).join("")}
        <li><span class="wf-link is-muted">${icon("right", 13)} Fallback</span><span class="wf-hint">when no route matches${(step.otherwise || []).length ? "" : " (empty: carry on)"}</span></li></ol>
        ${ro ? "" : `<button type="button" class="wf-btn" data-action="harbor--workflow-builder#addRoute">${icon("plus", 14)} Add route</button>`}</div>`
    }
    const outputs = this.outputsOf(step)
    const outs = `<div class="wf-section"><h3>What it gives later steps</h3><ul class="wf-outs">${outputs.map(([k, , d]) =>
      `<li><code>steps.${esc(step.key)}.${esc(k)}</code>${d ? ` <span class="wf-hint">${esc(d)}</span>` : ""}</li>`).join("")}</ul></div>`
    const actions = ro ? "" : `<div class="wf-panel-actions">
      <button type="button" class="wf-btn" data-action="harbor--workflow-builder#moveStep" data-dir="-1" title="Move earlier">${icon("left", 14)} Earlier</button>
      <button type="button" class="wf-btn" data-action="harbor--workflow-builder#moveStep" data-dir="1" title="Move later">Later ${icon("right", 14)}</button>
      <button type="button" class="wf-btn" data-action="harbor--workflow-builder#duplicateStep">${icon("copy", 14)} Duplicate</button>
      <button type="button" class="wf-btn is-danger" data-action="harbor--workflow-builder#deleteStep">${icon("trash", 14)} Delete</button>
    </div>`
    const problems = this.editing ? this.problems(step) : []
    const errs = this.serverErrorsFor(step.key)
    const warn = errs.length || problems.length ? `<p class="wf-warn">${esc([...errs, ...problems.map((p) => `Needs ${p}.`)].join(" "))}</p>` : ""
    return this.panelHead(mod.color, mod.icon, step.name || mod.label, mod.label) +
      `<p class="wf-desc">${esc(mod.description || "")}</p>${warn}` +
      fields.join("") + routes + outs + (ro ? "" : this.dataPicker(path)) + actions
  }

  triggerPanel(path) {
    const t = this.get(path)
    if (!t) return ""
    const kind = this.triggerFor(t)
    const ro = !this.editing
    const kinds = (this.catalogValue.triggers || []).map((k) => `<option value="${k.kind}"${k.kind === t.kind ? " selected" : ""}${k.soon ? " disabled" : ""}>${esc(k.label)}${k.soon ? " (soon)" : ""}</option>`).join("")
    const kindField = `<label class="wf-field"><span class="wf-label">Starts on</span>
      <select class="field w-full" data-trigger-kind ${ro ? "disabled" : ""}>${kinds}</select></label>`
    const fields = (kind.fields || []).map((f) => this.field(f, t[f.name], ro, path, { trigger: t })).join("")
    const actions = ro ? "" : `<div class="wf-panel-actions"><button type="button" class="wf-btn is-danger" data-action="harbor--workflow-builder#deleteTrigger">${icon("trash", 14)} Delete trigger</button></div>`
    const data = ro ? "" : this.dataPicker(path, { only: "trigger" })
    return this.panelHead(kind.color, kind.icon, `Trigger: ${kind.label}`, "Starts a run") +
      `<p class="wf-desc">${esc(kind.description || "")}</p>` + kindField + fields + data + actions
  }

  routePanel(path) {
    const route = this.get(path)
    if (!route) return ""
    const ro = !this.editing
    const routerPath = path.slice(0, -2)
    const i = path[path.length - 1]
    return this.panelHead("#16A34A", "funnel", route.name || `Route ${i + 1}`, "A route out of the router") +
      `<p class="wf-desc">The router takes the first route whose filter passes, top to bottom. If none does, the fallback runs.</p>` +
      this.field({ name: "name", label: "Route name", kind: "text" }, route.name, ro, path) +
      this.field({ name: "when", label: "Take this route if", kind: "condition" }, route.when, ro, path, { scopePath: routerPath }) +
      (ro ? "" : this.dataPicker(routerPath)) +
      (ro ? "" : `<div class="wf-panel-actions">
        <button type="button" class="wf-btn" data-action="harbor--workflow-builder#moveRoute" data-dir="-1">${icon("up", 14)} Up</button>
        <button type="button" class="wf-btn" data-action="harbor--workflow-builder#moveRoute" data-dir="1">${icon("down", 14)} Down</button>
        <button type="button" class="wf-btn is-danger" data-action="harbor--workflow-builder#deleteRoute">${icon("trash", 14)} Delete route</button></div>`)
  }

  fallbackPanel() {
    return this.panelHead("#16A34A", "right", "Fallback route", "When no route's filter passes") +
      `<p class="wf-desc">Steps on the fallback run when no other route matched. Leave it empty to carry straight on after the router.</p>`
  }

  settingsPanel() {
    const s = this.def.settings
    const fields = (this.catalogValue.settings || []).map((f) => this.field(f, s[f.name], !this.editing, ["settings"])).join("")
    const inputs = (this.def.inputs || []).map((inp, i) => `<li class="wf-kv">
        <input class="field font-mono text-xs" value="${esc(inp.key)}" placeholder="pr" data-input-key="${i}" ${this.editing ? "" : "disabled"} aria-label="Input name">
        <input class="field text-xs flex-1" value="${esc(inp.description || "")}" placeholder="what it is" data-input-desc="${i}" ${this.editing ? "" : "disabled"} aria-label="Input description">
        ${this.editing ? `<button type="button" class="wf-iconbtn" data-action="harbor--workflow-builder#removeInput" data-index="${i}" aria-label="Remove input">${icon("x", 14)}</button>` : ""}</li>`).join("")
    return this.panelHead("#4F46E5", "sliders", "Workflow settings", "Name, key, what it takes over, and defaults") +
      `<div data-details-slot></div><div class="wf-section"><h3>Defaults</h3>${fields}</div>
      <div class="wf-section"><h3>Inputs</h3><p class="wf-hint mb-2">What this workflow expects when another one runs it (read as <code>input.&lt;name&gt;</code>).</p>
        <ul class="space-y-2">${inputs || '<li class="wf-hint">None declared.</li>'}</ul>
        ${this.editing ? `<button type="button" class="wf-btn mt-2" data-action="harbor--workflow-builder#addInput">${icon("plus", 14)} Add input</button>` : ""}</div>`
  }

  jsonPanel() {
    return this.panelHead("#475569", "braces", "Definition (JSON)", "The same workflow as text") +
      `<p class="wf-desc">Edit and apply, or copy it somewhere safe. Saving still checks everything on the server.</p>
      <textarea class="field w-full font-mono text-xs leading-relaxed" rows="26" spellcheck="false" data-json aria-label="Definition JSON" ${this.editing ? "" : "readonly"}>${esc(JSON.stringify(this.def, null, 2))}</textarea>
      <p class="wf-warn" data-json-error hidden></p>
      ${this.editing ? `<div class="wf-panel-actions"><button type="button" class="wf-btn is-primary" data-action="harbor--workflow-builder#applyJson">Apply</button></div>` : ""}`
  }

  helpPanel() {
    const c = this.catalogValue
    const gates = (c.gates || []).map((g) => `<li><b>${esc(g.name)}</b> <span class="wf-hint">${esc(g.where)} · reads ${esc(g.reads)}</span><br>${esc(g.does)}</li>`).join("")
    const ops = (c.operators || []).map((o) => `<code>${esc(o.label)}</code>`).join(" ")
    const fields = (list) => list.map(([k, t, d]) => `<li><code>${esc(k)}</code> <span class="wf-hint">${esc(t)}${d ? ` · ${esc(d)}` : ""}</span></li>`).join("")
    return this.panelHead("#4F46E5", "help", "How workflows work", "Gates, data and operators") +
      `<div class="wf-section"><h3>Gates: what decides what runs</h3><ul class="wf-ref">${gates}</ul></div>
      <div class="wf-section"><h3>Filter operators</h3><p class="leading-7">${ops}</p>
        <p class="wf-hint mt-1">A filter is OR groups of AND rules. Text compares ignoring case. “is one of” takes a comma-separated list.</p></div>
      <div class="wf-section"><h3>Data a step can use</h3>
        <p class="wf-hint mb-1">Write <code>{{path}}</code> in any text field, or click a chip in the Data panel.</p>
        <h4 class="wf-h4">trigger.*: the event that started the run</h4><ul class="wf-ref">${fields(c.data?.trigger || [])}</ul>
        <h4 class="wf-h4">run.*</h4><ul class="wf-ref">${fields(c.data?.run || [])}</ul>
        <h4 class="wf-h4">steps.&lt;key&gt;.*: what earlier steps returned</h4><p class="wf-hint">Each module lists its outputs in its panel. Every step also has <code>status</code>.</p>
        <h4 class="wf-h4">input.*, settings.*, loop.&lt;key&gt;.iteration</h4><p class="wf-hint">What a calling workflow passed in, this workflow's settings, and the pass number inside a repeat.</p>
        ${this.modules.some((m) => (m.fields || []).some((f) => f.scope === "event")) ? `<h4 class="wf-h4">event.*: only in a Wait's filter</h4><p class="wf-hint">The incoming event, with the same fields as trigger.*.</p>` : ""}</div>
      ${c.reference_url ? `<p class="wf-hint"><a class="underline" href="${esc(c.reference_url)}">Open the full reference</a></p>` : ""}`
  }

  outputsOf(step) {
    const mod = this.moduleFor(step)
    const outs = [...(mod.outputs || [])]
    if (mod.dynamic_outputs) (step[mod.dynamic_outputs] || []).forEach((k) => outs.unshift([k, "value", "returned by the agent"]))
    outs.push(["status", "string", "ok, error or skipped"])
    return outs
  }

  // ── fields ───────────────────────────────────────────────────────────
  field(f, value, ro, path, ctx = {}) {
    const id = `wf-${path.join("-")}-${f.name}`.replace(/[^a-zA-Z0-9_-]/g, "_")
    const req = f.required ? '<span class="wf-req" title="required">*</span>' : ""
    const help = f.help ? `<span class="wf-hint">${esc(f.help)}</span>` : ""
    const dis = ro ? "disabled" : ""
    const data = `data-field="${esc(f.name)}" data-kind="${esc(f.kind)}"`
    const ph = f.placeholder ? `placeholder="${esc(f.placeholder)}"` : ""
    const wrap = (inner, { label = true } = {}) =>
      `<div class="wf-field">${label ? `<label class="wf-label" for="${id}">${esc(f.label)}${req}</label>` : `<span class="wf-label">${esc(f.label)}${req}</span>`}${inner}${help}</div>`
    switch (f.kind) {
      case "text":
        return wrap(`<input id="${id}" class="field w-full${ctx.mono || f.name === "key" ? " font-mono text-sm" : ""}" value="${esc(value ?? "")}" ${ph} ${data} ${dis}>`)
      case "template":
        return wrap(`<input id="${id}" class="field w-full font-mono text-sm" value="${esc(value ?? "")}" ${ph} ${data} data-template ${dis}>`)
      case "textarea":
        return wrap(`<textarea id="${id}" class="field w-full font-mono text-sm" rows="4" ${ph} ${data} data-template ${dis}>${esc(value ?? "")}</textarea>`)
      case "number":
        return wrap(`<input id="${id}" type="number" class="field w-32" value="${esc(value ?? "")}" ${f.min ? `min="${f.min}"` : ""} ${f.max ? `max="${f.max}"` : ""} ${ph} ${data} ${dis}>`)
      case "bool":
        return `<div class="wf-field"><label class="flex items-center gap-2 text-sm"><input id="${id}" type="checkbox" ${value ? "checked" : ""} ${data} ${dis}> ${esc(f.label)}</label>${help}</div>`
      case "select": {
        const opts = (f.options || []).map(([v, l]) => `<option value="${esc(v)}"${String(value ?? "") === String(v) ? " selected" : ""}>${esc(l)}</option>`).join("")
        return wrap(`<select id="${id}" class="field w-full" ${data} ${dis}>${opts}</select>`)
      }
      case "multi": {
        const list = Array.isArray(value) ? value : (value ? [value] : [])
        let suggest = ""
        if (f.suggest_from) {
          const owner = ctx.step || ctx.trigger || {}
          const options = (f.suggestions || {})[owner[f.suggest_from]] || []
          if (options.length) {
            suggest = `<div class="wf-checks">${options.map((o) => `<label><input type="checkbox" value="${esc(o)}" data-multi-check="${esc(f.name)}" ${list.includes(o) ? "checked" : ""} ${dis}> ${esc(o)}</label>`).join("")}</div>`
            return wrap(suggest, { label: false })
          }
        }
        return wrap(`<input id="${id}" class="field w-full" value="${esc(list.join(", "))}" ${ph} ${data} ${dis}><span class="wf-hint">Separate with commas.</span>`)
      }
      case "agent": {
        const agents = this.catalogValue.agents || []
        const tasks = this.catalogValue.task_types || []
        const opt = (v, l) => `<option value="${esc(v)}"${value === v ? " selected" : ""}>${esc(l)}</option>`
        const known = value && !agents.some((a) => a.key === value) && !tasks.some((t) => `task:${t}` === value)
        return wrap(`<select id="${id}" class="field w-full" ${data} ${dis}>
          <option value="">Choose…</option>
          ${known ? opt(value, value) : ""}
          <optgroup label="Whoever /agents assigns">${tasks.map((t) => opt(`task:${t}`, `agent for ${t.replace(/_/g, " ")}`)).join("")}</optgroup>
          <optgroup label="A specific agent">${agents.map((a) => opt(a.key, a.name ? `${a.name} (${a.key})` : a.key)).join("")}</optgroup></select>`)
      }
      case "workflow": {
        const wfs = this.catalogValue.workflows || []
        return wrap(`<select id="${id}" class="field w-full" ${data} ${dis}><option value="">Choose…</option>
          ${wfs.map((w) => `<option value="${esc(w.key)}"${value === w.key ? " selected" : ""}>${esc(w.name)} (${esc(w.key)})</option>`).join("")}</select>`)
      }
      case "workspace": {
        const made = this.allSteps().filter(({ step }) => this.makesWorkspace(step))
        const opts = (f.required ? [] : (f.options || []))
          .concat(made.map(({ step }) => [step.key, `${step.name || step.key} (made by ${step.key})`]))
        return wrap(`<select id="${id}" class="field w-full" ${data} ${dis}>${f.required ? '<option value="">Choose…</option>' : ""}
          ${opts.map(([v, l]) => `<option value="${esc(v)}"${String(value ?? "") === v ? " selected" : ""}>${esc(l)}</option>`).join("")}</select>`)
      }
      case "kv": {
        const entries = Object.entries(value || {})
        return wrap(`<ul class="space-y-2" data-kv="${esc(f.name)}">${entries.map(([k, v], i) => `<li class="wf-kv">
            <input class="field w-24 font-mono text-xs" value="${esc(k)}" data-kv-key="${i}" aria-label="Name" ${dis}>
            <input class="field flex-1 font-mono text-xs" value="${esc(typeof v === "string" ? v : JSON.stringify(v))}" data-kv-val="${i}" data-template aria-label="Value" ${dis}>
            ${ro ? "" : `<button type="button" class="wf-iconbtn" data-action="harbor--workflow-builder#kvRemove" data-name="${esc(f.name)}" data-index="${i}" aria-label="Remove">${icon("x", 14)}</button>`}</li>`).join("")}</ul>
          ${ro ? "" : `<button type="button" class="wf-btn mt-2" data-action="harbor--workflow-builder#kvAdd" data-name="${esc(f.name)}">${icon("plus", 14)} Add value</button>`}`, { label: false })
      }
      case "condition":
        return wrap(this.conditionEditor(f, value, ro, path, ctx), { label: false })
      default:
        return ""
    }
  }

  // Make-style filter: OR groups of AND rules. Nested shapes (not, any
  // inside all…) aren't drawable as rows, so those are edited as JSON.
  normalizeCond(c) {
    const leaf = (x) => x && typeof x === "object" && "path" in x && !x.all && !x.any && !x.not
    if (!c || (typeof c === "object" && Object.keys(c).length === 0)) return []
    if (leaf(c)) return [[c]]
    if (c.all && c.all.every(leaf)) return [c.all]
    if (c.any && c.any.every((g) => leaf(g) || (g.all && g.all.every(leaf)))) return c.any.map((g) => (leaf(g) ? [g] : g.all))
    return null
  }

  denormalizeCond(groups) {
    const gs = groups.map((g) => g.filter((r) => r.path)).filter((g) => g.length)
    if (!gs.length) return null
    const one = (g) => (g.length === 1 ? g[0] : { all: g })
    return gs.length === 1 ? one(gs[0]) : { any: gs.map(one) }
  }

  conditionEditor(f, value, ro, path, ctx) {
    const groups = this.normalizeCond(value)
    const label = ""
    if (groups === null) {
      return `${label}<textarea class="field w-full font-mono text-xs" rows="6" data-cond-json="${esc(f.name)}" ${ro ? "disabled" : ""}>${esc(JSON.stringify(value, null, 2))}</textarea>
        <span class="wf-hint">This filter uses a nested form (not / mixed groups), so it's edited as JSON.</span>`
    }
    const ops = this.catalogValue.operators || []
    const scope = f.scope === "event" ? "event" : f.scope === "trigger" ? "trigger" : "any"
    const listId = `wf-paths-${scope}-${path.join("-")}`.replace(/[^a-zA-Z0-9_-]/g, "_")
    const suggestions = this.dataPaths(ctx.scopePath || path, { scope, inside: f.scope === "inside" })
    const datalist = `<datalist id="${listId}">${suggestions.map((s) => `<option value="${esc(s)}">`).join("")}</datalist>`
    const rows = (groups.length ? groups : [[{ path: "", op: "eq", value: "" }]]).map((g, gi) => {
      const rules = g.map((r, ri) => {
        const op = ops.find((o) => o.op === r.op) || ops[0]
        const val = Array.isArray(r.values) ? r.values.join(", ") : (r.value ?? "")
        return `<div class="wf-rule" data-group="${gi}" data-rule="${ri}">
          ${ri > 0 ? '<span class="wf-and">AND</span>' : ""}
          <input class="field w-full font-mono text-xs" list="${listId}" value="${esc(r.path || "")}" placeholder="${scope === "event" ? "event.review_state" : "steps.review.verdict"}" data-cond-path data-cond-name="${esc(f.name)}" ${ro ? "disabled" : ""} aria-label="Field">
          <div class="flex gap-2">
            <select class="field text-xs" data-cond-op data-cond-name="${esc(f.name)}" ${ro ? "disabled" : ""} aria-label="Operator">
              ${ops.map((o) => `<option value="${o.op}"${o.op === op.op ? " selected" : ""}>${esc(o.label)}</option>`).join("")}</select>
            <input class="field flex-1 text-xs" value="${esc(val)}" ${op.arity === 0 ? "hidden" : ""} placeholder="${op.arity === "many" ? "a, b, c" : "value"}" data-cond-value data-cond-name="${esc(f.name)}" ${ro ? "disabled" : ""} aria-label="Value">
            ${ro ? "" : `<button type="button" class="wf-iconbtn" data-action="harbor--workflow-builder#condRemove" data-name="${esc(f.name)}" aria-label="Remove rule">${icon("x", 14)}</button>`}
          </div></div>`
      }).join("")
      return `<div class="wf-group">${gi > 0 ? '<div class="wf-or">OR</div>' : ""}${rules}
        ${ro ? "" : `<button type="button" class="wf-link text-xs" data-action="harbor--workflow-builder#condAddAnd" data-name="${esc(f.name)}" data-group="${gi}">+ AND rule</button>`}</div>`
    }).join("")
    return `${label}<div class="wf-cond" data-cond="${esc(f.name)}">${datalist}${rows}
      ${ro ? "" : `<button type="button" class="wf-btn mt-1" data-action="harbor--workflow-builder#condAddOr" data-name="${esc(f.name)}">+ OR rule</button>`}</div>`
  }

  // ── data picker ──────────────────────────────────────────────────────
  dataSources(path, { scope = "any", inside = false } = {}) {
    const c = this.catalogValue
    const groups = []
    if (scope === "event") {
      groups.push({ label: "The event", color: "#D97706", items: (c.data?.trigger || []).map(([k, , d]) => ({ path: `event.${k}`, label: k, d })) })
      return groups
    }
    groups.push({ label: "Trigger", color: "#24292F", items: (c.data?.trigger || []).map(([k, , d]) => ({ path: `trigger.${k}`, label: k, d })) })
    if (scope === "trigger") return groups
    groups.push({ label: "Run", color: "#4F46E5", items: (c.data?.run || []).map(([k, , d]) => ({ path: `run.${k}`, label: k, d })) })
    if ((this.def.inputs || []).length) groups.push({ label: "Input", color: "#0D9488", items: this.def.inputs.map((i) => ({ path: `input.${i.key}`, label: i.key, d: i.description })) })
    const settings = Object.keys(this.def.settings || {})
    if (settings.length) groups.push({ label: "Settings", color: "#64748B", items: settings.map((k) => ({ path: `settings.${k}`, label: k })) })
    // Steps that run before this one (and, for a repeat's own filter, the
    // steps inside it).
    const order = this.allSteps()
    const here = order.findIndex((s) => samePath(s.path, path))
    const isCleanup = path[0] === "finally"
    order.forEach((s, i) => {
      const before = here === -1 ? true : i < here
      const within = inside && i > here && s.path.length > path.length && samePath(s.path.slice(0, path.length), path)
      const fromMain = isCleanup && s.path[0] === "steps"
      if (!(before || within || fromMain)) return
      const mod = this.moduleFor(s.step)
      groups.push({ label: s.step.name || s.step.key, color: mod.color, icon: mod.icon, step: true,
        items: this.outputsOf(s.step).map(([k, , d]) => ({ path: `steps.${s.step.key}.${k}`, label: k, d })) })
    })
    // Repeat counters for the loops this step sits in.
    const loops = order.filter((s) => s.step.type === "loop" && s.path.length < path.length && samePath(s.path, path.slice(0, s.path.length)))
    if (inside) loops.push(order[here])
    loops.filter(Boolean).forEach((s) => groups.push({ label: `${s.step.name || s.step.key} (repeat)`, color: "#16A34A",
      items: [{ path: `loop.${s.step.key}.iteration`, label: "iteration", d: "which pass this is, from 1" }] }))
    return groups
  }

  dataPaths(path, opts) { return this.dataSources(path, opts).flatMap((g) => g.items.map((i) => i.path)) }

  // Like Make's mapping panel: the nearest earlier steps first, then the
  // trigger and the run (folded away once there are steps to pick from).
  dataPicker(path, { only } = {}) {
    const groups = this.dataSources(path, { scope: only || "any" })
    const fixed = groups.filter((g) => !g.step)
    const steps = groups.filter((g) => g.step).reverse()
    const ordered = [...steps, ...fixed]
    const group = (g) => `<details class="wf-data-group" ${g.step || !steps.length ? "open" : ""}>
        <summary class="wf-data-label"><span class="wf-dotc" style="--c:${g.color}"></span>${esc(g.label)} <span class="wf-hint">${g.items.length}</span></summary>
        <div class="wf-chips">${g.items.map((i) => `<button type="button" class="wf-chip" style="--c:${g.color}" data-insert="${esc(i.path)}" title="${esc(i.d ? `${i.path}: ${i.d}` : i.path)}">${esc(i.label)}</button>`).join("")}</div></details>`
    return `<div class="wf-data"><p class="wf-data-title">Data you can use <span class="wf-hint">click a field, then a chip</span></p>
      ${ordered.map(group).join("")}</div>`
  }

  // ── panel wiring: every input writes straight into the definition ───
  wirePanel(p) {
    const sel = this.selected
    const target = () => (sel.kind === "settings" ? this.def.settings : this.get(sel.path))
    p.querySelectorAll("[data-insert]").forEach((chip) => chip.addEventListener("click", () => this.insertData(chip.dataset.insert)))
    p.querySelectorAll("[data-field]").forEach((el) => {
      const ev = el.type === "checkbox" || el.tagName === "SELECT" ? "change" : "input"
      el.addEventListener(ev, () => {
        const obj = target()
        if (!obj) return
        const name = el.dataset.field
        const kind = el.dataset.kind
        let v
        if (kind === "bool") v = el.checked || undefined
        else if (kind === "number") v = el.value === "" ? undefined : Number(el.value)
        else if (kind === "multi") v = el.value.split(",").map((s) => s.trim()).filter(Boolean)
        else v = el.value
        if (name === "key" && sel.kind === "step") return this.renameKey(obj, el)
        if (v === undefined || v === "" || (Array.isArray(v) && !v.length)) delete obj[name]
        else obj[name] = v
        // The event decides which actions are offered.
        this.commit({ panel: name === "event" })
      })
    })
    p.querySelectorAll("[data-multi-check]").forEach((el) => el.addEventListener("change", () => {
      const obj = target()
      const name = el.dataset.multiCheck
      const picked = [...p.querySelectorAll(`[data-multi-check="${name}"]:checked`)].map((c) => c.value)
      if (picked.length) obj[name] = picked
      else delete obj[name]
      this.commit()
    }))
    p.querySelector("[data-trigger-kind]")?.addEventListener("change", (e) => {
      const t = this.get(sel.path)
      Object.keys(t).forEach((k) => delete t[k])
      t.kind = e.target.value
      // Its kind's starting values, leaving out the empty ones: the form
      // shows those as empty already.
      const starts = (this.triggerFor(t).defaults || {})
      Object.keys(starts).forEach((k) => { if (starts[k] !== "") t[k] = clone(starts[k]) })
      this.commit({ panel: true })
    })
    // Filters
    p.querySelectorAll(".wf-cond").forEach((box) => {
      const name = box.dataset.cond
      const sync = () => {
        const groups = []
        box.querySelectorAll(".wf-rule").forEach((row) => {
          const gi = Number(row.dataset.group)
          const op = row.querySelector("[data-cond-op]").value
          const raw = row.querySelector("[data-cond-value]").value
          const arity = (this.catalogValue.operators || []).find((o) => o.op === op)?.arity
          const rule = { path: row.querySelector("[data-cond-path]").value.trim(), op }
          if (arity === "many") rule.values = raw.split(",").map((s) => s.trim()).filter(Boolean)
          else if (arity !== 0) rule.value = raw
          ;(groups[gi] ||= []).push(rule)
        })
        const obj = target()
        const cond = this.denormalizeCond(groups.filter(Boolean))
        if (cond) obj[name] = cond
        else delete obj[name]
        this.commit()
      }
      box.addEventListener("input", sync)
      box.addEventListener("change", (e) => {
        if (e.target.matches("[data-cond-op]")) {
          const arity = (this.catalogValue.operators || []).find((o) => o.op === e.target.value)?.arity
          const val = e.target.closest(".wf-rule").querySelector("[data-cond-value]")
          val.hidden = arity === 0
          val.placeholder = arity === "many" ? "a, b, c" : "value"
        }
        sync()
      })
    })
    p.querySelectorAll("[data-cond-json]").forEach((el) => el.addEventListener("change", () => {
      try {
        target()[el.dataset.condJson] = JSON.parse(el.value)
        this.commit()
      } catch { el.classList.add("ring-2", "ring-red-300") }
    }))
    // Named values (a Run workflow step's input)
    p.querySelectorAll("[data-kv]").forEach((list) => {
      const name = list.dataset.kv
      list.addEventListener("input", () => {
        const obj = {}
        list.querySelectorAll(".wf-kv").forEach((row) => {
          const k = row.querySelector("[data-kv-key]").value.trim()
          if (k) obj[k] = row.querySelector("[data-kv-val]").value
        })
        target()[name] = obj
        this.commit()
      })
    })
    // Workflow inputs (settings panel)
    p.querySelectorAll("[data-input-key], [data-input-desc]").forEach((el) => el.addEventListener("input", () => {
      const i = Number(el.dataset.inputKey ?? el.dataset.inputDesc)
      const inp = this.def.inputs[i]
      if (el.dataset.inputKey !== undefined) inp.key = el.value.trim()
      else inp.description = el.value
      this.commit()
    }))
  }

  insertData(path) {
    const f = this.lastField
    if (!f || !f.el.isConnected) {
      this.flash("Click a field first, then the data to put in it.")
      return
    }
    const el = f.el
    if (f.kind === "path") {
      el.value = path
    } else {
      const text = `{{${path}}}`
      const start = el.selectionStart ?? el.value.length
      const end = el.selectionEnd ?? el.value.length
      el.setRangeText(text, start, end, "end")
    }
    el.dispatchEvent(new Event("input", { bubbles: true }))
    el.focus()
  }

  flash(text) {
    const p = this.panelTarget
    let n = p.querySelector(".wf-flash")
    if (!n) { n = document.createElement("p"); n.className = "wf-flash"; n.setAttribute("role", "status"); p.prepend(n) }
    n.textContent = text
    clearTimeout(this.flashTimer)
    this.flashTimer = setTimeout(() => n.remove(), 2500)
  }

  renameKey(step, el) {
    const old = step.key
    const next = el.value.trim()
    if (!/^[a-z][a-z0-9_]*$/.test(next)) { el.classList.add("ring-2", "ring-red-300"); return }
    el.classList.remove("ring-2", "ring-red-300")
    if (next === old) return
    // Keep everything that read the old key pointing at the step.
    let json = JSON.stringify(this.def)
    json = json.split(`steps.${old}.`).join(`steps.${next}.`).split(`steps.${old}}}`).join(`steps.${next}}}`)
    this.def = JSON.parse(json)
    // Steps that run in the renamed workspace step follow it. A Create
    // workspace step's own `workspace` names a Workspace (/workspaces), not
    // a step, so it stays.
    this.allSteps().forEach(({ step: s }) => { if (!this.makesWorkspace(s) && s.workspace === old) s.workspace = next })
    this.get(this.selected.path).key = next
    this.commit()
  }

  // ── editing actions ──────────────────────────────────────────────────
  openPicker(e) {
    if (!this.editing) return
    e.stopPropagation()
    const el = e.currentTarget
    this.pickAt = { path: JSON.parse(el.dataset.path), index: Number(el.dataset.index) }
    this.showPicker(el, this.pickerModules())
  }

  openTriggerPicker(e) {
    e.stopPropagation()
    this.pickAt = { trigger: true }
    this.showPicker(e.currentTarget, this.pickerTriggers())
  }

  pickerModules() {
    const inLoop = this.pickAt.path.includes("steps") && this.pickAt.path.length > 1 &&
      this.pickAt.path.some((_, i) => this.get(this.pickAt.path.slice(0, i))?.type === "loop")
    const groups = {}
    this.modules.forEach((m, i) => {
      if (inLoop && m.inside_loop === false) return
      ;(groups[m.group] ||= []).push({ ...m, index: i })
    })
    return Object.entries(groups).map(([g, items]) => `<div class="wf-pick-group"><p>${esc(g)}</p>${items.map((m) =>
      `<button type="button" class="wf-pick" data-pick="${m.index}" data-search="${esc(`${m.label} ${m.group} ${m.description} ${m.type} ${m.action || ""}`.toLowerCase())}">
        <span class="wf-pick-bubble" style="--c:${m.color}">${icon(m.icon, 18, 2)}</span>
        <span class="min-w-0"><b>${esc(m.label)}</b><span>${esc(m.description)}</span></span></button>`).join("")}</div>`).join("")
  }

  pickerTriggers() {
    return `<div class="wf-pick-group"><p>Start the workflow when…</p>${(this.catalogValue.triggers || []).map((t, i) =>
      `<button type="button" class="wf-pick" data-pick-trigger="${i}" ${t.soon ? "disabled" : ""} data-search="${esc(`${t.label} ${t.description}`.toLowerCase())}">
        <span class="wf-pick-bubble" style="--c:${t.color}">${icon(t.icon, 18, 2)}</span>
        <span class="min-w-0"><b>${esc(t.label)}${t.soon ? " (soon)" : ""}</b><span>${esc(t.description)}</span></span></button>`).join("")}</div>`
  }

  showPicker(anchor, body) {
    const pk = this.pickerTarget
    pk.innerHTML = `<div class="wf-picker-head"><input type="search" class="field w-full" placeholder="Search modules" aria-label="Search modules" data-pick-search>
      <button type="button" class="wf-iconbtn" data-action="harbor--workflow-builder#closePicker" aria-label="Close">${icon("x", 16)}</button></div>
      <div class="wf-picker-body">${body}</div>`
    pk.hidden = false
    const vp = this.viewportTarget.getBoundingClientRect()
    const a = anchor.getBoundingClientRect()
    const w = Math.min(360, vp.width - 24)
    pk.style.width = `${w}px`
    pk.style.left = `${Math.min(Math.max(12, a.left - vp.left + a.width / 2 - w / 2), vp.width - w - 12)}px`
    pk.style.top = `${Math.min(Math.max(12, a.top - vp.top + a.height + 8), Math.max(12, vp.height - 420))}px`
    const search = pk.querySelector("[data-pick-search]")
    search.focus()
    search.addEventListener("input", () => {
      const q = search.value.toLowerCase().trim()
      pk.querySelectorAll(".wf-pick").forEach((b) => { b.hidden = q && !b.dataset.search.includes(q) })
      pk.querySelectorAll(".wf-pick-group").forEach((g) => { g.hidden = ![...g.querySelectorAll(".wf-pick")].some((b) => !b.hidden) })
    })
    search.addEventListener("keydown", (e) => {
      if (e.key === "Enter") { e.preventDefault(); pk.querySelector(".wf-pick:not([hidden]):not([disabled])")?.click() }
      if (e.key === "Escape") this.closePicker()
    })
    pk.querySelectorAll("[data-pick]").forEach((b) => b.addEventListener("click", () => this.addModule(this.modules[Number(b.dataset.pick)])))
    pk.querySelectorAll("[data-pick-trigger]").forEach((b) => b.addEventListener("click", () => this.addTrigger(this.catalogValue.triggers[Number(b.dataset.pickTrigger)])))
  }

  closePicker() {
    if (!this.hasPickerTarget) return
    this.pickerTarget.hidden = true
    this.pickerTarget.innerHTML = ""
  }

  addModule(mod) {
    const { path, index } = this.pickAt
    const list = this.get(path)
    if (!Array.isArray(list)) return
    const step = { key: this.uniqueKey(mod.action ? mod.action.split(".").pop() : mod.label), type: mod.type, name: mod.label, ...clone(mod.defaults || {}) }
    if (mod.action) step.action = mod.action
    list.splice(index, 0, step)
    this.closePicker()
    this.selected = { kind: "step", path: [...path, index] }
    this.commit({ panel: true })
  }

  addTrigger(kind) {
    const t = { kind: kind.kind, ...clone(kind.defaults || {}) }
    this.def.triggers.push(t)
    this.closePicker()
    this.selected = { kind: "trigger", path: ["triggers", this.def.triggers.length - 1] }
    this.commit({ panel: true })
  }

  deleteTrigger() {
    const i = this.selected.path[1]
    this.def.triggers.splice(i, 1)
    this.selected = null
    this.commit({ panel: true })
  }

  deleteStep() {
    const path = this.selected.path
    const list = this.get(path.slice(0, -1))
    list.splice(path[path.length - 1], 1)
    this.selected = null
    this.commit({ panel: true })
  }

  duplicateStep() {
    const path = this.selected.path
    const list = this.get(path.slice(0, -1))
    const i = path[path.length - 1]
    const copy = clone(list[i])
    const used = new Set(this.allSteps().map((x) => x.step.key))
    const rekey = (s) => {
      let k = s.key
      let n = 2
      while (used.has(k)) k = `${s.key}_${n++}`
      used.add(k)
      s.key = k
      ;(s.branches || []).forEach((b) => (b.steps || []).forEach(rekey))
      ;(s.otherwise || []).forEach(rekey)
      if (s.type === "loop") (s.steps || []).forEach(rekey)
    }
    rekey(copy)
    if (copy.name) copy.name = `${copy.name} (copy)`
    list.splice(i + 1, 0, copy)
    this.selected = { kind: "step", path: [...path.slice(0, -1), i + 1] }
    this.commit({ panel: true })
  }

  moveStep(e) {
    const dir = Number(e.currentTarget.dataset.dir)
    const path = this.selected.path
    const list = this.get(path.slice(0, -1))
    const i = path[path.length - 1]
    const j = i + dir
    if (j < 0 || j >= list.length) return
    ;[list[i], list[j]] = [list[j], list[i]]
    this.selected = { kind: "step", path: [...path.slice(0, -1), j] }
    this.commit({ panel: true })
  }

  addRoute() {
    const step = this.get(this.selected.path)
    step.branches ||= []
    step.branches.push({ name: `Route ${step.branches.length + 1}`, when: { path: "", op: "eq", value: "" }, steps: [] })
    this.selected = { kind: "route", path: [...this.selected.path, "branches", step.branches.length - 1] }
    this.commit({ panel: true })
  }

  deleteRoute() {
    const path = this.selected.path
    const router = this.get(path.slice(0, -2))
    router.branches.splice(path[path.length - 1], 1)
    this.selected = { kind: "step", path: path.slice(0, -2) }
    this.commit({ panel: true })
  }

  moveRoute(e) {
    const dir = Number(e.currentTarget.dataset.dir)
    const path = this.selected.path
    const list = this.get(path.slice(0, -1))
    const i = path[path.length - 1]
    const j = i + dir
    if (j < 0 || j >= list.length) return
    ;[list[i], list[j]] = [list[j], list[i]]
    this.selected = { kind: "route", path: [...path.slice(0, -1), j] }
    this.commit({ panel: true })
  }

  condAddAnd(e) { this.condMutate(e, (groups, gi) => groups[gi].push({ path: "", op: "eq", value: "" })) }
  condAddOr(e) { this.condMutate(e, (groups) => groups.push([{ path: "", op: "eq", value: "" }])) }
  condRemove(e) {
    const row = e.currentTarget.closest(".wf-rule")
    const gi = Number(row.dataset.group)
    const ri = Number(row.dataset.rule)
    this.condMutate(e, (groups) => { groups[gi].splice(ri, 1); if (!groups[gi].length) groups.splice(gi, 1) })
  }

  // Structural changes to a filter keep blank rows (so a new row shows up),
  // which denormalizeCond would drop, so they edit a draft of the groups.
  condMutate(e, fn) {
    const name = e.currentTarget.dataset.name
    const obj = this.selected.kind === "settings" ? this.def.settings : this.get(this.selected.path)
    const groups = this.normalizeCond(obj[name]) || []
    if (!groups.length) groups.push([{ path: "", op: "eq", value: "" }])
    fn(groups, Number(e.currentTarget.dataset.group || 0))
    const gs = groups.filter((g) => g.length)
    obj[name] = gs.length === 1 ? (gs[0].length === 1 ? gs[0][0] : { all: gs[0] }) : gs.length ? { any: gs.map((g) => (g.length === 1 ? g[0] : { all: g })) } : undefined
    if (obj[name] === undefined) delete obj[name]
    this.commit({ panel: true })
  }

  kvAdd(e) {
    const obj = this.get(this.selected.path)
    const name = e.currentTarget.dataset.name
    obj[name] ||= {}
    let k = "value"
    let n = 2
    while (k in obj[name]) k = `value_${n++}`
    obj[name][k] = ""
    this.commit({ panel: true })
  }

  kvRemove(e) {
    const obj = this.get(this.selected.path)
    const name = e.currentTarget.dataset.name
    const key = Object.keys(obj[name] || {})[Number(e.currentTarget.dataset.index)]
    delete obj[name][key]
    this.commit({ panel: true })
  }

  addInput() { (this.def.inputs ||= []).push({ key: "", description: "" }); this.commit({ panel: true }) }
  removeInput(e) {
    this.def.inputs.splice(Number(e.currentTarget.dataset.index), 1)
    if (!this.def.inputs.length) delete this.def.inputs
    this.commit({ panel: true })
  }

  applyJson() {
    const el = this.panelTarget.querySelector("[data-json]")
    const err = this.panelTarget.querySelector("[data-json-error]")
    try {
      const parsed = JSON.parse(el.value)
      if (typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("the definition must be an object")
      this.def = parsed
      this.def.triggers ||= []
      this.def.steps ||= []
      this.def.finally ||= []
      this.def.settings ||= {}
      this.parseFailed = false
      this.selected = null
      this.commit({ panel: true })
      this.fit()
    } catch (x) {
      err.hidden = false
      err.textContent = `Not applied: ${x.message}`
    }
  }

  key(e) {
    const typing = e.target.closest("input, textarea, select, [contenteditable]")
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z" && !typing) {
      e.preventDefault()
      e.shiftKey ? this.redo() : this.undo()
    } else if (e.key === "Escape") {
      this.closePicker()
      if (!typing) this.closePanel()
    } else if ((e.key === "Delete" || e.key === "Backspace") && !typing && this.selected?.kind === "step") {
      e.preventDefault()
      this.deleteStep()
    }
  }
}
