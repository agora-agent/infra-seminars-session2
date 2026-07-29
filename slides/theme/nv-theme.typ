#import "@preview/touying:0.6.3": *
#import "@preview/cetz:0.5.1"

#let palette = (
  page: rgb("#FFFFFF"),
  surface: rgb("#FAFAFA"),
  surface-strong: rgb("#FFFFFF"),
  surface-muted: rgb("#EFF1F3"),
  ink: rgb("#171A17"),
  muted: rgb("#6E746D"),
  border: rgb("#39413A"),
  grid: rgb("#D8DCE0"),
  accent: rgb("#156082"),
  lime: rgb("#156082"),
  lime-dark: rgb("#0E4A64"),
  panel: rgb("#EDF2F6"),
  scheduler: rgb("#DCE7EE"),
  teal: rgb("#6E746D"),
  orange: rgb("#156082"),
  violet: rgb("#6E746D"),
  on-accent: rgb("#FFFFFF"),
)

// 字体约定（对齐 Session 2.pptx）：正文统一微软雅黑（本机缺失时回退思源黑体/
// 苹方等黑体）；标题 = 黑体中文 + Times New Roman 英文，英文按 pptx 排版为
// 大写 + 首字母放大。Times New Roman 无 smcp 特性，small-caps 效果手工合成：
// 每个拉丁词首字母全尺寸、其余字母大写并缩到 0.82em（对齐 pptx 的 44/36pt）。
#let font-body = ("Microsoft YaHei", "Noto Sans SC", "PingFang SC", "Hiragino Sans GB", "Heiti SC")
#let font-title = ("Times New Roman", "Microsoft YaHei", "Noto Sans SC", "PingFang SC", "Hiragino Sans GB", "Heiti SC")

#let title-text(size: 1.4em, it) = text(
  font: font-title,
  size: size,
  weight: "bold",
  fill: palette.ink,
)[
  #show regex("[\p{Lu}\p{Ll}]+"): word => {
    let s = word.text
    upper(s.first()) + text(size: 0.82em)[#upper(s.slice(1))]
  }
  #it
]

// 品牌资产（对齐 Session 2.pptx）：wmhpc = 未名超算队，lcpu = Linux 俱乐部，
// linuxproj = “Linux 俱乐部项目”徽章（封面 / 章节页左下角）。
#let brand-mark-wmhpc = "../assets/wmhpc.svg"
#let brand-mark-lcpu = "../assets/lcpu.svg"
#let brand-badge-linuxproj = "../assets/linuxproj.svg"

// 内容页品牌区（对齐 Session 2.pptx，几何按 13.33in × 7.5in 坐标系换算）：
//   - 顶部 0.80in 处通栏 accent 分隔线（2pt）；
//   - 右上角 wmhpc 字标 + 竖直分隔线 + lcpu 圆形图标。
#let brand-chrome() = context {
  let sx = page.width / 13.33
  let sy = page.height / 7.5
  place(top + left, dy: 0.80 * sy, line(
    length: page.width,
    stroke: 2pt + palette.accent,
  ))
  place(top + right, dx: -0.16 * sx, dy: 0.06 * sy)[
    #grid(
      columns: 3,
      column-gutter: 0.15 * sx,
      align: horizon,
      image(brand-mark-wmhpc, height: 0.64 * sy),
      line(angle: 90deg, length: 0.68 * sy, stroke: 1.5pt + palette.ink),
      image(brand-mark-lcpu, height: 0.71 * sy),
    )
  ]
}

// 封面 / 章节页左下角的 “Linux 俱乐部项目” 徽章（对齐 Session 2.pptx：
// 位于 (0.13in, 6.96in)，宽 1.97in）。
#let brand-badge-corner() = context place(
  bottom + left,
  dx: 0.13 * page.width / 13.33,
  dy: -0.14 * page.height / 7.5,
  image(brand-badge-linuxproj, width: 1.97 * page.width / 13.33),
)

#let note(it) = text(size: 0.72em, fill: palette.ink, it)
// 强调只走 pptx 的思路：关键词加粗，不用颜色、不用框。
#let accent(it) = text(fill: palette.ink, weight: "bold", it)
#let kicker(it) = text(size: 0.72em, fill: palette.ink, weight: "bold", it)

// 证据标签：纯文本方括号，不用胶囊框。
#let chip(it, fill: none, stroke: none) = text(size: 0.6em, fill: palette.muted)[\[#it\]]

#let panel-box(
  body,
  fill: none,
  stroke: none,
  inset: 0pt,
  height: auto,
) = block(
  width: 100%,
  height: height,
  inset: inset,
  body,
)

// 不用圆角框表强调：标题加粗一行 + 直接排内容。
#let callout(title, body, fill: none) = block(width: 100%, [
  #text(weight: "bold")[#title]
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
  let header(self) = pad(top: 0.1em, left: 0.2em)[
    #align(top + left)[
      #block(width: 78%)[
        #title-text(size: 1.4em)[
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

  let self = utils.merge-dicts(
    self,
    config-page(
      fill: palette.page,
      background: brand-chrome(),
      header: header,
      footer: none,
    ),
  )

  let new-setting = body => {
    set text(
      font: font-body,
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

// Act / Part 封面页（对齐 Session 2.pptx 第 2 页）：白底，页面中部居中的大标题，
// 下方居中作者 / 日期 / 两家组织，左下角 linuxproj 徽章；objective / question
// 若有则以小字居中放在信息块下方。几何按 pptx 的 13.33in × 7.5in 坐标系换算。
#let new-section-slide(config: (:), body) = touying-slide-wrapper(self => {
  let spec = _section-spec(body)
  self = utils.merge-dicts(
    self,
    config-common(freeze-slide-counter: true),
    config-page(
      fill: palette.page,
      margin: 0pt,
      background: brand-badge-corner(),
    ),
    config,
  )
  let info = self.info

  touying-slide(self: self, context {
    let sy = page.height / 7.5
    set align(center)
    place(top + center, dy: 2.55 * sy)[
      #title-text(size: 2.1em)[
        #utils.display-current-heading(level: 1)
      ]
    ]
    place(top + center, dy: 5.06 * sy)[
      #text(size: 0.72em)[
        #info.author \
        #info.date
      ]
      #v(0.55em)
      #text(size: 0.64em)[
        北京大学未名超算队 · Weiming Supercomputing Team \
        北京大学学生 Linux 俱乐部 · Linux Club of Peking University
      ]
    ]
    if spec.objective != none or spec.question != none {
      place(top + center, dy: 3.95 * sy)[
        #block(width: 72%)[
          #text(size: 0.62em)[
            #if spec.objective != none [
              #text(weight: "bold")[目标：]#spec.objective
            ]
            #if spec.question != none [
              \
              #text(weight: "bold")[问题：]#spec.question
            ]
          ]
        ]
      ]
    }
  })
})

#let focus-slide(config: (:), body) = touying-slide-wrapper(self => {
  self = utils.merge-dicts(
    self,
    config-common(freeze-slide-counter: true),
    config-page(fill: palette.ink, margin: 2em),
    config,
  )
  set text(
    font: font-body,
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
      margin: (top: 3.6em, bottom: 1.55em, x: 1.2em),
      header-ascent: 35%,
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
          font: font-body,
          size: 20pt,
        )
        body
      },
      alert: utils.alert-with-primary-color,
    ),
    config-colors(
      primary: palette.accent,
      primary-light: palette.panel,
      secondary: palette.muted,
      neutral-lightest: palette.page,
      neutral-dark: palette.ink,
      neutral-darkest: palette.ink,
    ),
    ..args,
  )

  body
}
