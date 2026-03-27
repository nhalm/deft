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
          # Readability
          {Credo.Check.Readability.WithCustomTaggedTuple, []},

          # Warnings
          {Credo.Check.Warning.MixEnv, []},

          # Design
          {Credo.Check.Design.AliasUsage, []},

          # Refactoring — complexity
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 7]},
          {Credo.Check.Refactor.Nesting, [max_nesting: 2]},
          {Credo.Check.Refactor.FunctionArity, [max_arity: 5]},
          {Credo.Check.Refactor.PerceivedComplexity, [max_complexity: 9]},
          {Credo.Check.Refactor.ABCSize, [max_size: 30]}
        ]
      }
    }
  ]
}
