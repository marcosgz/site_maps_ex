[
  parallel: true,
  skipped: false,
  tools: [
    {:compiler, "mix compile --warnings-as-errors --force"},
    {:credo, "mix credo --strict"},
    {:doctor, "mix doctor --summary"},
    {:npm_test, false},
    {:sobelow, false},
    {:gettext, false}
  ]
]
