#import "@preview/touying:0.6.3": touying-reducer, pause
#import "@preview/cetz:0.5.1"
#import "./nv-theme.typ": palette

#let responsive-canvas(
  logical-size: (100, 100),
  padding: 8pt,
  max-unit: none,
  ..args,
) = layout(size => {
  let available-width = calc.max(size.width - 2 * padding, 0pt)
  let available-height = calc.max(size.height - 2 * padding, 0pt)
  let unit = calc.min(
    available-width / logical-size.at(0),
    available-height / logical-size.at(1),
  )
  if max-unit != none {
    unit = calc.min(unit, max-unit)
  }

  block(
    width: size.width,
    height: size.height,
    align(center + horizon, cetz.canvas(length: unit, ..args)),
  )
})

#let animated-canvas = touying-reducer.with(
  reduce: responsive-canvas,
  cover: cetz.draw.hide.with(bounds: true),
)

#let _sm-shell() = {
  import cetz.draw: *
  rect((0, 0), (108, 70), fill: palette.panel, radius: 2.4)
  content((3.2, 68), anchor: "text", text(size: 6.8pt, fill: palette.ink, [SM]))
}

#let _sm-scheduler(x, idx, highlight: false) = {
  import cetz.draw: *

  let pale = palette.surface-strong
  let width = 21
  let pipe-top = 50.2
  let pipe-bottom = 32.5
  let bus-y = 30.2

  rect(
    (x, 24),
    (x + width, 65),
    fill: palette.scheduler,
    stroke: 0.85pt + palette.teal,
    radius: 1.8,
  )
  content(
    (x + width / 2, 62.8),
    text(size: 6.25pt, fill: palette.ink, "Warp Scheduler " + str(idx)),
  )

  // C$ and I$ use equal boxes and connect directly into the issue stage.
  rect((x + 1.7, 57.3), (x + 6.5, 60.9), fill: pale, radius: 0.8)
  rect((x + 14.5, 57.3), (x + 19.3, 60.9), fill: pale, radius: 0.8)
  content((x + 4.1, 59.1), text(size: 5.7pt, fill: palette.ink, "C$"))
  content((x + 16.9, 59.1), text(size: 5.7pt, fill: palette.ink, "I$"))

  rect((x + 1.2, 52.0), (x + 19.8, 56.1), fill: pale)
  content((x + 10.5, 54.05), text(size: 6.2pt, fill: palette.ink, [Issue Stage]))
  line((x + 4.1, 57.3), (x + 4.1, 56.1))
  line((x + 16.9, 57.3), (x + 16.9, 56.1))

  // Execution boxes connect with straight center-aligned stems.
  rect((x + 1.3, pipe-bottom), (x + 5.2, pipe-top), fill: pale)
  rect((x + 6.1, pipe-bottom), (x + 10.0, pipe-top), fill: pale)
  rect(
    (x + 15.8, pipe-bottom),
    (x + 19.7, pipe-top),
    fill: if highlight { palette.orange } else { pale },
  )
  content(
    (x + 3.25, 41.35),
    angle: 90deg,
    text(size: 5.9pt, fill: palette.ink, [Fast Math]),
  )
  content(
    (x + 8.05, 41.35),
    angle: 90deg,
    text(size: 5.9pt, fill: palette.ink, [XU]),
  )
  content((x + 13.0, 41.35), text(size: 7.5pt, fill: palette.ink, [...]))
  content(
    (x + 17.75, 41.35),
    angle: 90deg,
    text(
      size: 5.9pt,
      fill: if highlight { palette.on-accent } else { palette.ink },
      [Tensor],
    ),
  )

  line((x + 3.25, 52.0), (x + 3.25, pipe-top))
  line((x + 8.05, 52.0), (x + 8.05, pipe-top))
  line((x + 17.75, 52.0), (x + 17.75, pipe-top))

  // A shared output bus makes every execution box visibly meet the register file.
  line((x + 3.25, pipe-bottom), (x + 3.25, bus-y))
  line((x + 8.05, pipe-bottom), (x + 8.05, bus-y))
  line((x + 17.75, pipe-bottom), (x + 17.75, bus-y))
  line((x + 3.25, bus-y), (x + 17.75, bus-y))
  line((x + 10.5, bus-y), (x + 10.5, 28.6))

  rect((x + 1.4, 24.7), (x + 19.6, 28.6), fill: pale, radius: 1.1)
  content((x + 10.5, 26.65), text(size: 6.25pt, fill: palette.ink, [Register File]))
}

#let _sm-mio() = {
  import cetz.draw: *

  let pale = palette.surface-strong
  let mio-fill = palette.scheduler
  let centers = (14.0, 35.5, 57.0, 78.5)

  rect(
    (2.5, 9.6),
    (105.5, 17.8),
    fill: mio-fill,
    stroke: 0.85pt + palette.violet,
    radius: 1.4,
  )
  content((5.2, 16.0), anchor: "text", text(size: 6.3pt, fill: palette.ink, [MIO]))

  // Four equal execution-pipeline cells with uniform gaps.
  for (x, label) in (
    (4.5, [ADU]),
    (26.0, [RTCore]),
    (47.5, [LSU]),
    (69.0, [TEX]),
  ) {
    rect((x, 10.8), (x + 19.0, 14.5), fill: pale)
    content((x + 9.5, 12.65), text(size: 5.7pt, fill: palette.ink, label))
  }
  content((96.0, 12.65), text(size: 7pt, fill: palette.ink, [...]))

  // Register-file centers connect vertically to the shared MIO boundary.
  for x in (14.5, 39.5, 68.5, 93.5) {
    line((x, 24.7), (x, 17.8))
  }

  // CBU and MIOC sit in the deliberately widened center gap.
  rect((50.3, 21.5), (57.7, 24.2), fill: pale)
  rect((50.3, 18.2), (57.7, 20.9), fill: pale)
  content((54.0, 22.85), text(size: 5.0pt, fill: palette.ink, [CBU]))
  content((54.0, 19.55), text(size: 4.8pt, fill: palette.ink, [MIOC]))
  line((54.0, 24.7), (54.0, 24.2))
  line((54.0, 21.5), (54.0, 20.9))
  line((54.0, 18.2), (54.0, 17.8))
}

#let _sm-cache() = {
  import cetz.draw: *

  let pale = palette.surface-strong

  rect((2.5, 1.8), (22.5, 5.8), fill: pale, stroke: 0.85pt + palette.violet, radius: 1.0)
  rect((24.0, 1.8), (105.5, 5.8), fill: pale, stroke: 0.85pt + palette.violet, radius: 1.0)
  content((12.5, 3.8), text(size: 5.9pt, fill: palette.ink, "IDC$"))
  content((64.75, 3.8), text(size: 6.0pt, fill: palette.ink, [L1TEX + Shared Memory]))

  line((14.0, 9.6), (14.0, 5.8))
  line((57.0, 9.6), (57.0, 5.8))
  line((78.5, 9.6), (78.5, 5.8))
  content((72.0, 0.7), text(size: 5.5pt, fill: palette.muted, [to / from L2]))
}

#let sm-mental-model(stage: 1) = {
  responsive-canvas(logical-size: (108, 70), padding: 6pt, {
    import cetz.draw: *

    let stage = calc.max(stage, 1)
    set-style(stroke: 0.75pt + palette.border)

    _sm-shell()
    if stage >= 1 { _sm-scheduler(4, 0, highlight: stage >= 6) }
    if stage >= 2 {
      _sm-scheduler(29, 1, highlight: stage >= 6)
      _sm-scheduler(58, 2, highlight: stage >= 6)
      _sm-scheduler(83, 3, highlight: stage >= 6)
    }
    if stage >= 4 { _sm-mio() }
    if stage >= 5 { _sm-cache() }
  })
}

// Reducer-native build: hidden future commands keep their bounds, so the
// complete SM has one fixed position and scale from the first subslide onward.
#let sm-mental-model-live() = {
  animated-canvas(logical-size: (108, 70), padding: 6pt, {
    import cetz.draw: *

    set-style(stroke: 0.75pt + palette.border)
    _sm-shell()
    _sm-scheduler(4, 0)

    (pause,)

    _sm-scheduler(29, 1)
    _sm-scheduler(58, 2)
    _sm-scheduler(83, 3)

    (pause,)

    _sm-mio()

    (pause,)

    _sm-cache()
  })
}

#let warp-state-names = (
  "unused",
  "active",
  "stalled",
  "eligible",
  "selected",
)

#let warp-cycle(
  label,
  slots,
  issue: "issued",
  cue: none,
) = {
  assert(slots.len() == 8, message: "warp-cycle requires exactly 8 resident slots")
  for state in slots {
    assert(state in warp-state-names, message: "unknown warp state: " + state)
  }
  assert(issue in ("issued", "bubble", "none"), message: "unknown issue state: " + issue)
  (label: label, slots: slots, issue: issue, cue: cue)
}

#let warp-step(
  previous,
  label,
  updates: (),
  issue: auto,
  cue: none,
) = {
  let slots = previous.slots
  for update in updates {
    let (slot, state) = update
    assert(slot >= 0 and slot < slots.len(), message: "warp slot index out of range")
    assert(state in warp-state-names, message: "unknown warp state: " + state)
    slots.at(slot) = state
  }
  warp-cycle(
    label,
    slots,
    issue: if issue == auto { previous.issue } else { issue },
    cue: cue,
  )
}

#let default-warp-trace = {
  let n = warp-cycle(
    "N",
    ("stalled", "stalled", "stalled", "selected", "eligible", "unused", "unused", "unused"),
    issue: "issued",
    cue: (to-next: true),
  )
  let n1 = warp-step(
    n,
    "N+1",
    updates: ((4, "active"),),
    issue: "issued",
  )
  let n2 = warp-step(
    n1,
    "N+2",
    updates: ((3, "active"),),
    issue: "bubble",
  )
  let n3 = warp-step(
    n2,
    "N+3",
    updates: (
      (1, "eligible"),
      (2, "selected"),
      (3, "stalled"),
      (4, "stalled"),
    ),
    issue: "issued",
  )
  (n, n1, n2, n3)
}

#let warp-trace-metrics(trace) = {
  let active = 0
  let eligible = 0
  for cycle in trace {
    for state in cycle.slots {
      if state != "unused" { active += 1 }
      if state in ("eligible", "selected") { eligible += 1 }
    }
  }
  let capacity = trace.len() * 8
  (
    cycles-active: trace.len(),
    warps-active: active,
    occupancy: calc.round(active / capacity * 100, digits: 1),
    warps-stalled: active - eligible,
    warps-eligible: eligible,
    issue-bubbles: trace.filter(cycle => cycle.issue == "bubble").len(),
  )
}

#let _warp-selected-slot(cycle) = {
  let selected = none
  for (slot, state) in cycle.slots.enumerate() {
    if selected == none and state == "selected" { selected = slot }
  }
  selected
}

#let render-warp-trace(
  trace,
  upto: none,
) = {
  assert(trace.len() > 0, message: "render-warp-trace requires at least one cycle")
  let visible-count = if upto == none {
    trace.len()
  } else {
    calc.max(1, calc.min(upto, trace.len()))
  }
  let logical-width = calc.max(80, 49.2 + (trace.len() - 1) * 9.6)

  responsive-canvas(logical-size: (logical-width, 56), padding: 6pt, {
    import cetz.draw: *

    let fills = (
      unused: palette.surface-strong,
      active: rgb("#D4D7D1"),
      stalled: rgb("#9AA09A"),
      eligible: palette.accent,
      selected: palette.accent.lighten(45%),
    )

    let state-fill(state) = fills.at(state)
    let right-edge = logical-width - 1

    rect((1, 6), (logical-width, 55), stroke: none, fill: none)
    rect((2, 7), (25, 54), fill: palette.surface-muted, stroke: none, radius: 2.4)
    rect((28, 7), (right-edge, 54), fill: palette.surface-muted, stroke: none, radius: 2.4)

    let hatch-cell(x, y, width: 7.0, height: 3.4) = {
      let span = calc.min(width - 1.4, height - 1.0)
      for offset in (0.0, 1.45, 2.9) {
        line(
          (x + 0.7 + offset, y + 0.5),
          (x + 0.7 + offset + span, y + 0.5 + span),
          stroke: 0.32pt + palette.lime-dark,
        )
      }
    }

    let legend-item(y, state, label) = {
      rect((4.2, y), (9.3, y + 3.8), fill: state-fill(state), stroke: none, radius: 0.8)
      if state == "selected" {
        hatch-cell(4.2, y + 0.15, width: 5.1, height: 3.5)
      }
      content(
        (11.0, y + 1.9),
        anchor: "text",
        text(size: 10.8pt, weight: "medium", fill: palette.ink, label),
      )
    }

    content((4.2, 49.7), anchor: "text", text(size: 11.6pt, weight: "bold", fill: palette.ink, [Warp states]))
    legend-item(42.4, "unused", [Unused])
    legend-item(35.9, "active", [Active])
    legend-item(29.4, "stalled", [Stalled])
    legend-item(22.9, "eligible", [Eligible])
    legend-item(16.4, "selected", [Selected])
    content((4.2, 10.2), anchor: "text", text(size: 8.5pt, fill: palette.muted, [8 resident slots]))

    content((31.0, 49.7), anchor: "text", text(size: 8.8pt, weight: "medium", fill: palette.muted, [CYCLE]))
    content((31.0, 39.0), angle: 90deg, text(size: 8.2pt, weight: "medium", fill: palette.muted, [WARP SLOT]))

    for (idx, cycle) in trace.enumerate() {
      if idx < visible-count {
        let x = 38.0 + idx * 9.6
        let width = 7.2
        content((x + width / 2, 49.6), text(size: 10.2pt, weight: "bold", fill: palette.ink, cycle.label))
        rect((x, 17.2), (x + width, 46.0), fill: palette.surface-strong, stroke: 0.45pt + palette.grid, radius: 1.4)

        for (slot, state) in cycle.slots.enumerate() {
          let y = 17.7 + slot * 3.48
          rect(
            (x + 0.45, y),
            (x + width - 0.45, y + 3.18),
            fill: state-fill(state),
            stroke: none,
            radius: 0.45,
          )
          if state == "selected" {
            hatch-cell(x + 0.45, y, width: width - 0.9, height: 3.18)
          }
        }

        if cycle.issue == "bubble" {
          circle((x + width / 2, 12.0), radius: 2.0, fill: rgb("#E3E6E3"), stroke: none)
          content((x + width / 2, 12.0), text(size: 7.3pt, weight: "bold", fill: palette.ink, [×]))
        } else if cycle.issue == "issued" {
          rect((x, 9.7), (x + width, 14.3), fill: fills.selected, stroke: none, radius: 1.15)
          hatch-cell(x, 10.25, width: width, height: 3.5)
        }

        if cycle.cue != none and cycle.cue.at("to-next", default: false) and idx + 1 < visible-count {
          let from-slot = _warp-selected-slot(cycle)
          let to-slot = _warp-selected-slot(trace.at(idx + 1))
          if from-slot != none and to-slot != none {
            let from-y = 19.29 + from-slot * 3.48
            let to-y = 19.29 + to-slot * 3.48
            line(
              (x + width - 0.2, from-y),
              (x + width + 1.2, calc.max(from-y, to-y) + 1.5),
              (x + 9.6 + 0.2, to-y),
              stroke: 1.0pt + palette.orange,
              mark: (end: ">"),
            )
          }
        }
      }
    }

    content((31.0, 11.7), anchor: "text", text(size: 8.8pt, weight: "medium", fill: palette.muted, [ISSUE]))
  })
}

#let warp-scheduler-statistics(
  stage: 1,
  trace: default-warp-trace,
) = render-warp-trace(
  trace,
  upto: calc.min(calc.max(stage, 1) + 1, trace.len()),
)
