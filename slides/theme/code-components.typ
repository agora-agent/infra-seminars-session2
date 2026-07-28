#import "./_vendor/codly/codly.typ" as codly
#import "./nv-theme.typ": palette

#let code-languages = (
  typst: (name: "Typst", color: palette.teal),
  rust: (name: "Rust", color: rgb("#B95D37")),
  python: (name: "Python", color: rgb("#3E78A8")),
  py: (name: "Python", color: rgb("#3E78A8")),
  cpp: (name: "C++", color: rgb("#5B6CB2")),
  c: (name: "C", color: rgb("#6B7280")),
  cuda: (name: "CUDA", color: palette.lime-dark),
  bash: (name: "Shell", color: palette.border),
  sh: (name: "Shell", color: palette.border),
)

#let code-themes = (
  schematic-light: "./_assets/code-themes/schematic-light.tmTheme",
  typst-default: auto,
)

#let code-syntaxes = (
  "./_assets/syntaxes/CUDA.sublime-syntax",
)

#let inline-code(it) = box(
  inset: (x: 0.34em, y: 0.10em),
  outset: (y: 0.03em),
  radius: 3pt,
  fill: palette.surface-muted,
  stroke: 0.45pt + palette.grid,
  text(
    font: ("JetBrains Mono", "Menlo", "DejaVu Sans Mono"),
    size: 0.80em,
    fill: palette.ink,
    it.text,
  ),
)

#let code-theme(
  syntax-theme: code-themes.schematic-light,
  body,
) = {
  set raw(theme: syntax-theme, syntaxes: code-syntaxes, tab-size: 2)
  show raw.where(block: true): set text(
    font: ("JetBrains Mono", "Menlo", "DejaVu Sans Mono"),
    size: 0.86em,
  )
  show: codly.codly-init.with()
  codly.codly(
    languages: code-languages,
    default-color: palette.teal,
    radius: 8pt,
    inset: (x: 0.34em, y: 0.21em),
    fill: palette.surface-muted,
    zebra-fill: none,
    stroke: 0.55pt + palette.grid,
    lang-inset: (x: 0.44em, y: 0.16em),
    lang-radius: 5pt,
    lang-stroke: none,
    lang-fill: palette.surface-strong,
    display-icon: false,
    display-name: true,
    number-format: n => text(
      size: 0.56em,
      fill: palette.muted.lighten(25%),
      str(n),
    ),
    number-align: right,
    number-placement: "inside",
    smart-indent: true,
    breakable: false,
    highlighted-default-color: palette.orange.lighten(74%),
    highlight-radius: 3pt,
  )
  show raw.where(block: false): inline-code
  body
}

#let code-block(
  body,
  title: none,
  numbers: true,
  highlighted-lines: none,
  highlights: none,
  fill: palette.surface-muted,
) = codly.local(
  filename: title,
  number-format: if numbers {
    n => text(size: 0.56em, fill: palette.muted.lighten(25%), str(n))
  } else {
    none
  },
  highlighted-lines: highlighted-lines,
  highlights: highlights,
  fill: fill,
  body,
)

#let code-note(title, body) = block(
  width: 100%,
  inset: 0.72em,
  radius: 8pt,
  fill: palette.panel,
  stroke: 0.55pt + palette.grid,
)[
  #text(size: 0.72em, weight: "bold", fill: palette.lime-dark)[#title]
  #v(0.30em)
  #text(size: 0.76em)[#body]
]
