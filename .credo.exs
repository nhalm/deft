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

          # Refactoring
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.Nesting, [max_nesting: 3]}
        ]
      }
    }
  ]
}
