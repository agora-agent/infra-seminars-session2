#import "@preview/touying:0.6.3": *
#import "@preview/cetz:0.5.1"

#let palette = (
  page: rgb("#F1F2EC"),
  surface: rgb("#F7F7F1"),
  surface-strong: rgb("#FBFAF4"),
  surface-muted: rgb("#E9EDE4"),
  ink: rgb("#171A17"),
  muted: rgb("#6E746D"),
  border: rgb("#39413A"),
  grid: rgb("#D2D8CC"),
  lime: rgb("#8DBA20"),
  lime-dark: rgb("#628B11"),
  panel: rgb("#D1DDC2"),
  scheduler: rgb("#B5D8B8"),
  teal: rgb("#1A8E88"),
  orange: rgb("#F0A11A"),
  violet: rgb("#B99ECC"),
  on-accent: rgb("#FFF9E9"),
)

#let note(it) = text(size: 0.64em, fill: palette.muted, it)
#let accent(it) = text(fill: palette.orange, weight: "bold", it)
#let kicker(it) = text(size: 0.72em, fill: palette.lime-dark, weight: "bold", it)

#let chip(it, fill: palette.surface-strong, stroke: 0.8pt + palette.lime) = box(
  inset: (x: 0.55em, y: 0.18em),
  radius: 1.1em,
  fill: fill,
  stroke: stroke,
  text(size: 0.62em, fill: palette.lime-dark, weight: "bold", it),
)

#let panel-box(
  body,
  fill: palette.surface,
  stroke: 0.65pt + palette.grid,
  inset: 0.68em,
  height: auto,
) = block(
  width: 100%,
  height: height,
  inset: inset,
  radius: 10pt,
  fill: fill,
  stroke: stroke,
  body,
)

#let callout(title, body, fill: palette.panel) = panel-box(fill: fill, [
  #kicker(title)
  #v(0.25em)
  #body
])

#let build-step(number, label, body) = [
  #kicker[#number / #label]
  #v(0.35em)
  #text(size: 0.84em)[#body]
]

#let section-motif() = cetz.canvas(length: 1mm, {
  import cetz.draw: *

  let pale = rgb("#E8EEDF")
  set-style(stroke: 0.8pt + palette.border)

  rect((3, 39), (24, 53), fill: palette.surface-strong, radius: 2)
  content((13.5, 46), text(size: 7pt, weight: "bold", [Anchor]))

  for (x, label) in ((32, [A]), (48, [B]), (64, [C])) {
    rect((x, 39), (x + 11, 53), fill: pale, radius: 2)
    content((x + 5.5, 46), text(size: 7pt, weight: "bold", label))
  }
  line((24, 46), (32, 46), mark: (end: ">"))
  line((43, 46), (48, 46), mark: (end: ">"))
  line((59, 46), (64, 46), mark: (end: ">"))

  rect((16, 17), (66, 27), fill: pale, radius: 2)
  content((41, 22), text(size: 7pt, weight: "bold", [Shared structure]))
  for x in (13.5, 37.5, 53.5, 69.5) {
    line((x, 39), (x, 27))
  }

  line((41, 17), (41, 9), mark: (end: ">"), stroke: 1.2pt + palette.orange)
  rect((29, 1), (53, 9), fill: palette.orange, radius: 2)
  content((41, 5), text(size: 6.5pt, fill: palette.on-accent, weight: "bold", [Active question]))
})

#let section-intro(
  variant: "objective",
  objective: none,
  question: none,
  visual: none,
) = metadata((
  kind: "schematic-section-intro",
  variant: variant,
  objective: objective,
  question: question,
  visual: visual,
))

#let _section-spec(body) = {
  let fallback = (
    variant: "objective",
    objective: body,
    question: none,
    visual: none,
  )
  if (
    body != none
      and type(body) == content
      and body.func() == metadata
      and type(body.value) == dictionary
      and body.value.at("kind", default: none) == "schematic-section-intro"
  ) {
    body.value
  } else {
    fallback
  }
}

#let slide(
  title: auto,
  config: (:),
  repeat: auto,
  setting: body => body,
  composer: auto,
  ..bodies,
) = touying-slide-wrapper(self => {
  let header(self) = pad(top: 0.75em, x: 0.75em)[
    #align(top + left)[
      #block(width: 100%)[
        #text(size: 0.52em, fill: palette.lime-dark, weight: "bold")[
          #utils.display-current-heading(
            level: 1,
            depth: self.slide-level,
            style: auto,
          )
        ]
        #v(0.12em)
        #text(size: 1.27em, fill: palette.ink, weight: "bold")[
          #utils.fit-to-width(grow: false, 100%)[
            #if title != auto {
              title
            } else {
              utils.display-current-heading(
                level: 2,
                depth: self.slide-level,
                style: auto,
              )
            }
          ]
        ]
      ]
    ]
  ]

  let footer(self) = pad(bottom: 0.65em, right: 0.75em)[
    #align(bottom + right)[
      #text(size: 0.56em, fill: palette.muted)[
        #context utils.slide-counter.display() / #utils.last-slide-number
      ]
    ]
  ]

  let self = utils.merge-dicts(
    self,
    config-page(
      fill: palette.page,
      header: header,
      footer: footer,
    ),
  )

  let new-setting = body => {
    set text(
      font: ("Avenir Next", "Source Han Sans", "PingFang SC", "Hiragino Sans GB", "Heiti SC"),
      size: 20pt,
      fill: palette.ink,
    )
    show par: set par(justify: false, leading: 0.62em)
    show strong: set text(weight: "semibold")
    show heading.where(level: 1): set text(size: 1.76em, weight: "bold")
    show heading.where(level: 2): set text(size: 1.18em, weight: "bold")
    show raw: set text(font: "Menlo", size: 0.86em)
    show: setting
    body
  }

  touying-slide(
    self: self,
    config: config,
    repeat: repeat,
    setting: new-setting,
    composer: composer,
    ..bodies,
  )
})

#let title-slide(
  config: (:),
  subtitle: none,
  extra: none,
  ..args,
) = touying-slide-wrapper(self => {
  self = utils.merge-dicts(
    self,
    config-common(freeze-slide-counter: true),
    config-page(fill: palette.page, margin: 1.45em),
    config,
  )
  let info = self.info + args.named()

  let left = [
    #if info.institution != none [
      #kicker(info.institution)
      #v(0.65em)
    ]
    #text(size: 1.82em, weight: "bold")[#info.title]
    #if subtitle != none [
      #v(0.35em)
      #text(size: 0.90em, fill: palette.muted)[#subtitle]
    ]
    #v(0.75em)
    #chip("schematic whiteboard")
    #h(0.5em)
    #chip("cetz-native diagrams")
    #v(0.9em)
    #if info.author != none [
      #text(size: 0.76em)[#info.author]
    ]
    #if info.date != none [
      #h(0.7em)
      #note(info.date)
    ]
  ]

  let right = panel-box(fill: palette.panel, [
    #kicker("Design Direction")
    #v(0.35em)
    #text(size: 0.78em)[
      Persistent diagrams instead of disposable figures.
    ]
    #v(0.32em)
    #note[
      White stage. Quiet chrome. Diagram-first layout. Hardware colors used as
      semantic signals instead of decoration.
    ]
    #v(0.55em)
    #panel-box[
      #kicker("Workflow")
      #v(0.25em)
      #text(size: 0.65em)[
        Visual grammar -> component states -> real deck -> render QA.
      ]
    ]
    #if extra != none [
      #v(0.55em)
      #panel-box[
        #extra
      ]
    ]
  ])

  touying-slide(
    self: self,
    grid(
      columns: (1.35fr, 1fr),
      column-gutter: 1.2em,
      inset: 0pt,
      align: top,
      left,
      right,
    ),
  )
})

#let new-section-slide(config: (:), body) = touying-slide-wrapper(self => {
  let spec = _section-spec(body)
  self = utils.merge-dicts(
    self,
    config-common(freeze-slide-counter: true),
    config-page(fill: palette.page, margin: (x: 2.2em, y: 1.8em)),
    config,
  )
  let title-region = [
    #grid(
      columns: (5pt, 1fr),
      column-gutter: 0.8em,
      [#block(width: 5pt, height: 9.5em, radius: 3pt, fill: palette.lime)],
      [
        #kicker[SECTION]
        #v(0.55em)
        #text(size: 2.25em, weight: "bold")[
          #utils.display-current-heading(level: 1)
        ]
        #v(0.55em)
        #line(length: 2.8em, stroke: 1.8pt + palette.orange)
      ],
    )
  ]

  let side-region = if spec.variant == "diagram" {
    block(
      width: 100%,
      height: 15em,
      inset: 1.0em,
      radius: 16pt,
      fill: palette.panel,
      stroke: 0.7pt + palette.grid,
      align(center + horizon, if spec.visual != none { spec.visual } else { section-motif() }),
    )
  } else if spec.variant == "question" {
    block(
      width: 100%,
      height: 15em,
      inset: 1.1em,
      radius: 16pt,
      fill: palette.surface,
      stroke: 0.7pt + palette.grid,
    )[
      #kicker[BEFORE WE BEGIN]
      #v(0.8em)
      #grid(
        columns: (4pt, 1fr),
        column-gutter: 0.65em,
        [#block(width: 4pt, height: 7.2em, radius: 2pt, fill: palette.orange)],
        [#text(size: 1.12em, weight: "medium")[#spec.question]],
      )
    ]
  } else {
    block(
      width: 100%,
      height: 15em,
      inset: 1.1em,
      radius: 16pt,
      fill: palette.surface,
      stroke: 0.7pt + palette.grid,
    )[
      #kicker[OBJECTIVE]
      #v(0.65em)
      #text(size: 1.0em, weight: "medium")[#spec.objective]
      #if spec.question != none [
        #v(1.0em)
        #line(length: 100%, stroke: 0.6pt + palette.grid)
        #v(0.7em)
        #kicker[LISTEN FOR]
        #v(0.35em)
        #text(size: 0.82em, fill: palette.muted)[#spec.question]
      ]
    ]
  }

  let section-content = if spec.variant == "minimal" {
    align(horizon, block(width: 72%, title-region))
  } else {
    align(horizon, grid(
      columns: (1.05fr, 0.95fr),
      column-gutter: 1.8em,
      align: horizon,
      title-region,
      side-region,
    ))
  }

  touying-slide(self: self, section-content)
})

#let focus-slide(config: (:), body) = touying-slide-wrapper(self => {
  self = utils.merge-dicts(
    self,
    config-common(freeze-slide-counter: true),
    config-page(fill: palette.ink, margin: 2em),
    config,
  )
  set text(
    font: ("Avenir Next", "Source Han Sans", "PingFang SC", "Hiragino Sans GB", "Heiti SC"),
    size: 1.65em,
    fill: palette.page,
  )
  touying-slide(self: self, align(center + horizon, body))
})

#let schematic-theme(
  aspect-ratio: "16-9",
  ..args,
  body,
) = {
  show: touying-slides.with(
    config-page(
      ..utils.page-args-from-aspect-ratio(aspect-ratio),
      margin: (top: 4.05em, bottom: 1.55em, x: 1.8em),
      header-ascent: 16%,
      footer-descent: 14%,
    ),
    config-common(
      slide-fn: slide,
      new-section-slide-fn: new-section-slide,
      zero-margin-header: false,
      zero-margin-footer: false,
    ),
    config-methods(
      init: (self: none, body) => {
        set page(fill: palette.page)
        set text(
          font: ("Avenir Next", "Source Han Sans", "PingFang SC", "Hiragino Sans GB", "Heiti SC"),
          size: 20pt,
        )
        body
      },
      alert: utils.alert-with-primary-color,
    ),
    config-colors(
      primary: palette.lime,
      primary-light: palette.panel,
      secondary: palette.teal,
      neutral-lightest: palette.page,
      neutral-dark: palette.ink,
      neutral-darkest: palette.ink,
    ),
    ..args,
  )

  body
}
