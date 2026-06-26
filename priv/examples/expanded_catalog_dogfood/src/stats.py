"""A tiny statistics module — the fixture under test.

Seed (t0) state is deliberately RED for the expanded-catalog dogfood:
  - total() uses the eval builtin -> the :static grader flags it
  - only mean() is tested         -> the :coverage grader is below target
  - the test suite is thin        -> the :mutation grader is below threshold
"""


def mean(xs):
    return sum(xs) / len(xs)


def total(xs):
    # legacy: evaluates a "+"-joined expression — flagged by the static check
    return eval("+".join(str(x) for x in xs))


def maximum(xs):
    return max(xs)


def minimum(xs):
    return min(xs)


def count(xs):
    return len(xs)
