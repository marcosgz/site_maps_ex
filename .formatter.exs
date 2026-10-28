locals_without_parens = [process: 1, process: 2, process: 3]

[
  inputs: ["{mix,.formatter,.credo,.check}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens],
  line_length: 120
]
