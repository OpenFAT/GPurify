# Names, loops and switches

Three statements save repetition in a deck: `let` names a value, `for` repeats statements over a
list, and `if` reads a block only when a switch is on. They expand where they stand, before
anything else reads the deck, so the rest of the language sees ordinary statements.

## let

```text
let <name> = <value>
```

`let` binds a name to any value: a number with its unit, a word, a quoted string, a list or a
tuple. Wherever a value is expected after that line, the name stands for it.

```text
let min_area = 0.083um2
let thin = ["nfet", "pfet"]
rule M1.A area(met1) >= min_area
```

A name is bound once in the whole deck. Layers and bindings share one set of names, so
`let met1 = ...` after `layer met1 = ...` is an error.

## for

```text
for <name> in [<value>, ...] { <statements> }
for (<name>, <name>, ...) in [(<value>, <value>, ...), ...] { <statements> }
```

`for` reads the statements in its braces once for each item of the list, with the loop names bound
to that item. With a tuple pattern, each item must be a tuple of the same length. The bindings end
with each pass, so the next item can bind the same names.

Inside a rule id or a `waive` id, `{name}` is replaced by the bound word or number. Layer names
and other names are not interpolated, so a loop cannot declare layers; it repeats rules, waivers
and stack lines.

```text
grid 5nm
layer met1       = gds(10, 0)
layer via1       = gds(11, 0)
layer met2       = gds(12, 0)
layer met1_label = gds(10, 5)

let metals = [(met1, 140nm), (met2, 200nm)]
for (m, w) in metals {
    rule {m}.width width(m) >= w
    rule {m}.space space(m) >= w
}

let cuts = [via1]
for c in cuts {
    rule {c}.size size(c) == 150nm x 150nm
}
```

The loop writes one rule per metal and check, each with its own id:

```text
rules:
  met1.width: ran, examined 2 shapes, found 1 violations
  met1.space: ran, examined 0 shapes, found 0 violations
  met2.width: ran, examined 1 shapes, found 0 violations
  met2.space: ran, examined 0 shapes, found 0 violations
  via1.size: ran, examined 1 shapes, found 0 violations
...
```

A loop runs only over a list written in the deck, so every deck finishes loading. An error inside
a loop body is reported once, not once per item.

## if

```text
if <name> { <statements> }
if not <name> { <statements> }
```

`if` reads its block only when the name is bound to `true`, and `if not` only when it is bound to
`false`. The name must be bound before the `if`, to `true` or `false` and nothing else. A block
that is switched off is skipped unread: an unknown layer or check inside it is not reported. Its
brackets and braces must still balance, since GPurify finds the block's end by them.

A switch is how a foundry deck turns groups of rules on and off, as a Calibre deck's `#DEFINE` and
`#IFDEF` do. Flip the switch where it is bound:

```text
let strict = false
if strict {
    rule M1.S.strict space(met1) >= 400nm
}
if not strict {
    rule M1.S.relaxed space(met1) >= 200nm
}
```

With `strict` false, the deck holds `M1.S.relaxed` and not `M1.S.strict`.
