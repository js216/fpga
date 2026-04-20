#set page(
  width: 6in,
  height: 9in,

  margin: (
    left: 0.75in,
    right: 0.75in,
    top: 0.75in,
    bottom: 0.7in,
  ),
)

#set par(
  justify: true,
  leading: 0.6em,
  //first-line-indent: 1.5em,
  //spacing: 0.6em,
)

#set text(size: 10pt)
#show raw: set text(size: 7.75pt)

#show heading: set block(below: 2em)
#set heading(numbering: "1.1   ")

#set page(
  header: context {
    let is-even = calc.even(here().page())
    let level = if is-even { 1 } else { 2 }
    let headings = query(selector(heading.where(level: level)).before(here()))
    let heading-text = if headings.len() > 0 {
      let h = headings.last()
      text(style: "italic")[#numbering(h.numbering, ..counter(heading).at(h.location())) #h.body]
    }

    grid(
      columns: (1fr, 1fr),
      align: (left, right),
      if is-even { counter(page).display() } else { heading-text },
      if is-even { heading-text } else { counter(page).display() },
    )
  }
)

#set list(marker: [--])

#counter(heading).step()
