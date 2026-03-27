%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: [
          "lib/",
          "test/",
          "config/",
          "mix.exs",
          ".formatter.exs"
        ]
      },
      checks: %{
        enabled: [
          {Credo.Check.Readability.WithCustomTaggedTuple, []},
          {Credo.Check.Warning.MixEnv, []},
          {Credo.Check.Design.AliasUsage, []},
          {Credo.Check.Refactor.ABCSize, [max_size: 30]},
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 7]},
          {Credo.Check.Refactor.FunctionArity, [max_arity: 5]},
          {Credo.Check.Refactor.Nesting, [max_nesting: 2]},
          {Credo.Check.Refactor.PerceivedComplexity, []},
          {Credo.Check.Refactor.LongQuoteBlocks, []}
        ]
      }
    }
  ]
}
