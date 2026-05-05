\ Small MANDEL test for sim (builds on ROM-builtin UM16* / F*)
\ Dimension rule: STEP-X = 768/WIDTH, STEP-Y = 512/HEIGHT
\ Override the defaults so the plot fits in the iverilog cycle budget.
16 CONSTANT WIDTH   48 CONSTANT STEP-X
8  CONSTANT HEIGHT  64 CONSTANT STEP-Y
10 CONSTANT MAXITER
\ Load blocks 34..39 (skip 33; our dimensions override it).
34 LOAD
MANDEL
BYE
