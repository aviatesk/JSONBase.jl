using BenchmarkTools, JSONBase, JSON, JSON3

json = """
{
"store": {
    "book": [
    {
        "category": "reference",
        "author": "Nigel Rees",
        "title": "Sayings of the Century",
        "price": 8.95
    },
    {
        "category": "fiction",
        "author": "Herman Melville",
        "title": "Moby Dick",
        "isbn": "0-553-21311-3",
        "price": 8.99
    },
    {
        "category": "fiction",
        "author": "J.R.R. Tolkien",
        "title": "The Lord of the Rings",
        "isbn": "0-395-19395-8",
        "price": 22.99
    }
    ],
    "bicycle": {
    "color": "red",
    "price": 19.95
    }
},
"expensive": 10
}
"""

@btime JSON.parse(json) #   2.181 μs (63 allocations: 4.09 KiB)
@btime JSON3.read(json) #   1.521 μs (7 allocations: 5.44 KiB)
@btime JSONBase.materialize(json) #  2.616 μs (64 allocations: 4.10 KiB)
@btime JSONBase.binary(json) #  1.429 μs (2 allocations: 608 bytes)
x = JSONBase.binary(json)
@btime JSONBase.materialize($x)
# 2.704 μs (142 allocations: 5.93 KiB)

x = JSON.parse(json)
@btime JSON.json(x)
@btime JSONBase.json(x)
x = JSON3.read(json)
@btime JSON3.write(x)

struct A
  a::Int
  b::Int
  c::Int
  d::Int
end

@btime JSONBase.materialize("""{ "a": 1,"b": 2,"c": 3,"d": 4}""", A)
  # 183.152 ns (3 allocations: 144 bytes)

mutable struct B
    a::Int
    b::Int
    c::Int
    d::Int
    B() = new()
end

JSONBase.mutable(::Type{B}) = true

@btime JSONBase.materialize!("""{ "a": 1,"b": 2,"c": 3,"d": 4}""", B)
  # 240.526 ns (1 allocation: 48 bytes)

@btime JSONBase.materialize("""{ "a": 1,"b": 2,"c": 3,"d": 4}""")
  # 364.038 ns (9 allocations: 624 bytes)

@btime JSON.parse("""{ "a": 1,"b": 2,"c": 3,"d": 4}""")
  # 597.848 ns (9 allocations: 640 bytes)

@btime JSON3.read("""{ "a": 1,"b": 2,"c": 3,"d": 4}""")
  # 1.325 μs (8 allocations: 1.11 KiB)

@btime JSON3.read("""{ "a": 1,"b": 2,"c": 3,"d": 4}""", A)
  # 1.129 μs (3 allocations: 544 bytes)

@btime JSONBase.binary("""{ "a": 1,"b": 2,"c": 3,"d": 4}""")
  # 138.166 ns (1 allocation: 576 bytes)

@btime JSONBase.json(nothing)
  # 23.654 ns (2 allocations: 88 bytes)
"null"

@btime JSON3.write(nothing)
  # 53.753 ns (2 allocations: 88 bytes)
"null"

@btime JSON.json(nothing)
  # 83.592 ns (4 allocations: 192 bytes)
"null"

