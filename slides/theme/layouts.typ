#import "./nv-theme.typ": palette, panel-box

// Content-layout layer. The theme owns page chrome and safe areas; these
// functions only compose semantic regions inside the content area.

#let fit-region(
  body,
  padding: 8pt,
  grow: true,
  max-scale: none,
) = layout(size => {
  let natural = measure(body)
  let available-width = calc.max(size.width - 2 * padding, 0pt)
  let available-height = calc.max(size.height - 2 * padding, 0pt)

  if natural.width == 0pt or natural.height == 0pt {
    body
  } else {
    let ratio = calc.min(
      available-width / natural.width,
      available-height / natural.height,
    )
    if not grow {
      ratio = calc.min(ratio, 1)
    }
    if max-scale != none {
      ratio = calc.min(ratio, max-scale)
    }

    block(
      width: size.width,
      height: size.height,
      align(center + horizon, scale(
        box(body, width: natural.width),
        origin: center,
        x: ratio * 100%,
        y: ratio * 100%,
        reflow: true,
      )),
    )
  }
})

#let region(
  body,
  role: "plain",
  placement: top + left,
  height: 100%,
  inset: auto,
  fill: auto,
  stroke: auto,
) = {
  let defaults = if role == "figure" {
    (fill: palette.surface, stroke: 0.65pt + palette.grid, inset: 0.68em)
  } else if role == "canvas" {
    (fill: palette.surface, stroke: 0.65pt + palette.grid, inset: 0.18em)
  } else if role == "stage" {
    (fill: none, stroke: none, inset: 0pt)
  } else if role == "support" {
    (fill: palette.panel, stroke: 0.65pt + palette.grid, inset: 0.68em)
  } else if role == "card" {
    (fill: palette.surface, stroke: 0.65pt + palette.grid, inset: 0.68em)
  } else {
    (fill: none, stroke: none, inset: 0pt)
  }

  let actual-fill = if fill == auto { defaults.fill } else { fill }
  let actual-stroke = if stroke == auto { defaults.stroke } else { stroke }
  let actual-inset = if inset == auto { defaults.inset } else { inset }

  if actual-fill == none and actual-stroke == none {
    block(width: 100%, height: height, align(placement, body))
  } else {
    panel-box(
      fill: actual-fill,
      stroke: actual-stroke,
      inset: actual-inset,
      height: height,
      align(placement, body),
    )
  }
}

#let split(
  primary,
  secondary,
  ratio: (1fr, 1fr),
  gutter: 0.8em,
  primary-role: "plain",
  secondary-role: "plain",
  primary-align: top + left,
  secondary-align: top + left,
) = block(
  width: 100%,
  height: 100%,
  grid(
    columns: ratio,
    column-gutter: gutter,
    align: top,
    region(primary, role: primary-role, placement: primary-align),
    region(secondary, role: secondary-role, placement: secondary-align),
  ),
)

#let diagram(
  figure,
  narrative,
  ratio: (2.15fr, 0.78fr),
  gutter: 0.8em,
  figure-role: "canvas",
  figure-padding: 8pt,
  figure-grow: true,
  figure-max-scale: none,
) = split(
  figure,
  narrative,
  ratio: ratio,
  gutter: gutter,
  primary-role: figure-role,
  primary-align: center + horizon,
)

#let compare(
  left,
  right,
  ratio: (1fr, 1fr),
  gutter: 0.8em,
  panel: true,
) = split(
  left,
  right,
  ratio: ratio,
  gutter: gutter,
  primary-role: if panel { "card" } else { "plain" },
  secondary-role: if panel { "card" } else { "plain" },
)

#let code-focus(
  code,
  narrative,
  ratio: (1.82fr, 0.82fr),
  gutter: 0.8em,
) = split(
  code,
  narrative,
  ratio: ratio,
  gutter: gutter,
  primary-role: "plain",
  secondary-role: "plain",
  primary-align: center + horizon,
)

#let code-compare(
  before,
  after,
  ratio: (1fr, 1fr),
  gutter: 0.65em,
) = split(
  before,
  after,
  ratio: ratio,
  gutter: gutter,
  primary-role: "plain",
  secondary-role: "plain",
  primary-align: center + horizon,
  secondary-align: center + horizon,
)

#let stack(
  top,
  bottom,
  rows: (auto, 1fr),
  gutter: 0.65em,
  top-role: "plain",
  bottom-role: "plain",
) = block(
  width: 100%,
  height: 100%,
  grid(
    rows: rows,
    row-gutter: gutter,
    region(top, role: top-role, height: auto),
    region(bottom, role: bottom-role),
  ),
)

#let full(body, role: "plain", placement: top + left) = region(
  body,
  role: role,
  placement: placement,
)

#let triptych(
  first,
  second,
  third,
  ratio: (1fr, 1fr, 1fr),
  gutter: 0.65em,
  panel: true,
) = block(
  width: 100%,
  height: 100%,
  grid(
    columns: ratio,
    column-gutter: gutter,
    align: top,
    region(first, role: if panel { "card" } else { "plain" }),
    region(second, role: if panel { "card" } else { "plain" }),
    region(third, role: if panel { "card" } else { "plain" }),
  ),
)

// Import this module as `layouts` to get semantic calls such as
// `#layouts.diagram(..)` and `#layouts.compare(..)`.
