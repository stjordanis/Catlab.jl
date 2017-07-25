""" Test the Syntax module.

The unit tests are sparse because many of the Doctrine tests are really just
tests of the Syntax module.
"""
module TestSyntax

using Base.Test
using Catlab

# Monoid
########

""" Signature of the theory of monoids.
"""
@signature Monoid(Elem) begin
  Elem::TYPE
  munit()::Elem
  mtimes(x::Elem,y::Elem)::Elem
end

""" Syntax for the theory of monoids.
"""
@syntax FreeMonoid Monoid

Elem(mod::Module, args...) = Elem(mod.Elem, args...)

@test isa(FreeMonoid, Module)
@test contains(string(Docs.doc(FreeMonoid)), "theory of monoids")
@test sort(names(FreeMonoid)) == sort([:FreeMonoid, :Elem])

x, y, z = Elem(FreeMonoid,:x), Elem(FreeMonoid,:y), Elem(FreeMonoid,:z)
@test isa(mtimes(x,y), FreeMonoid.Elem)
@test isa(munit(FreeMonoid.Elem), FreeMonoid.Elem)
@test mtimes(mtimes(x,y),z) != mtimes(x,mtimes(y,z))

# Test equality
@test x == Elem(FreeMonoid,:x)
@test x != y
@test Elem(FreeMonoid,"X") == Elem(FreeMonoid,"X")
@test Elem(FreeMonoid,"X") != Elem(FreeMonoid,"Y")

# Test hash
@test hash(x) == hash(x)
@test hash(x) != hash(y)
@test hash(mtimes(x,y)) == hash(mtimes(x,y))
@test hash(mtimes(x,y)) != hash(mtimes(x,z))

@syntax FreeMonoidAssoc Monoid begin
  mtimes(x::Elem, y::Elem) = associate(Super.mtimes(x,y))
end

x, y, z = [ Elem(FreeMonoidAssoc,sym) for sym in [:x,:y,:z] ]
e = munit(FreeMonoidAssoc.Elem)
@test mtimes(mtimes(x,y),z) == mtimes(x,mtimes(y,z))
@test mtimes(e,x) != x && mtimes(x,e) != x

@syntax FreeMonoidAssocUnit Monoid begin
  mtimes(x::Elem, y::Elem) = associate_unit(Super.mtimes(x,y), munit)
end

x, y, z = [ Elem(FreeMonoidAssocUnit,sym) for sym in [:x,:y,:z] ]
e = munit(FreeMonoidAssocUnit.Elem)
@test mtimes(mtimes(x,y),z) == mtimes(x,mtimes(y,z))
@test mtimes(e,x) == x && mtimes(x,e) == x

abstract type MonoidExpr{T} <: BaseExpr{T} end
@syntax FreeMonoidTyped(MonoidExpr) Monoid

x = Elem(FreeMonoidTyped.Elem, :x)
@test issubtype(FreeMonoidTyped.Elem, MonoidExpr)
@test isa(x, FreeMonoidTyped.Elem) && isa(x, MonoidExpr)

@signature Monoid(Elem) => MonoidNumeric(Elem) begin
  elem_int(x::Int)::Elem
end
@syntax FreeMonoidNumeric MonoidNumeric

x = elem_int(FreeMonoidNumeric.Elem, 1)
@test isa(x, FreeMonoidNumeric.Elem)
@test first(x) == 1

""" A monoid with two distinguished elements.
"""
@signature Monoid(Elem) => MonoidTwo(Elem) begin
  one()::Elem
  two()::Elem
end
""" The free monoid on two generators.
"""
@syntax FreeMonoidTwo MonoidTwo begin
  Elem(::Type{Elem}, value) = error("No extra generators allowed!")
end

x, y = one(FreeMonoidTwo.Elem), two(FreeMonoidTwo.Elem)
@test all(isa(expr, FreeMonoidTwo.Elem) for expr in [x, y, mtimes(x,y)])
@test_throws ErrorException Elem(FreeMonoidTwo, :x)

# Category
##########

@signature Category(Ob,Hom) begin
  Ob::TYPE
  Hom(dom::Ob, codom::Ob)::TYPE
  
  id(X::Ob)::Hom(X,X)
  compose(f::Hom(X,Y), g::Hom(Y,Z))::Hom(X,Z) <= (X::Ob, Y::Ob, Z::Ob)
  
  compose(fs::Vararg{Hom}) = foldl(compose, fs)
end

@syntax FreeCategory Category begin
  compose(f::Hom, g::Hom) = associate(Super.compose(f,g))
end

@test isa(FreeCategory, Module)
@test sort(names(FreeCategory)) == sort([:FreeCategory, :Ob, :Hom])

X, Y, Z, W = [ Ob(FreeCategory.Ob, sym) for sym in [:X, :Y, :Z, :W] ]
f, g, h = Hom(:f, X, Y), Hom(:g, Y, Z), Hom(:h, Z, W)
@test isa(X, FreeCategory.Ob) && isa(f, FreeCategory.Hom)
@test_throws MethodError FreeCategory.Hom(:f)
@test dom(f) == X
@test codom(f) == Y

@test isa(id(X), FreeCategory.Hom)
@test dom(id(X)) == X
@test codom(id(X)) == X

@test isa(compose(f,g), FreeCategory.Hom)
@test dom(compose(f,g)) == X
@test codom(compose(f,g)) == Z
@test isa(compose(f,f), FreeCategory.Hom) # Doesn't check domains.

@test compose(compose(f,g),h) == compose(f,compose(g,h))
@test compose(f,g,h) == compose(compose(f,g),h)
@test dom(compose(f,g,h)) == X
@test codom(compose(f,g,h)) == W

@syntax FreeCategoryStrict Category begin
  compose(f::Hom, g::Hom) = associate(Super.compose(f,g; strict=true))
end

X, Y = Ob(FreeCategoryStrict.Ob, :X), Ob(FreeCategoryStrict.Ob, :Y)
f, g = Hom(:f, X, Y), Hom(:g, Y, X)

@test isa(compose(f,g,f), FreeCategoryStrict.Hom)
@test_throws SyntaxDomainError compose(f,f)

# Functor
#########

@instance Monoid(String) begin
  munit(::Type{String}) = ""
  mtimes(x::String, y::String) = string(x,y)
end

F(expr; kw...) = functor((String,), expr; kw...)

x, y, z = Elem(FreeMonoid,:x), Elem(FreeMonoid,:y), Elem(FreeMonoid,:z)
gens = Dict(x => "x", y => "y", z => "z")
@test F(mtimes(x,mtimes(y,z)); generators=gens) == "xyz"
@test F(mtimes(x,munit(FreeMonoid.Elem)); generators=gens) == "x"

gen_terms = Dict(:Elem => (x) -> string(first(x)))
@test F(mtimes(x,mtimes(y,z)); generator_terms=gen_terms) == "xyz"
@test F(mtimes(x,munit(FreeMonoid.Elem)); generator_terms=gen_terms) == "x"

# Serialization
###############

# To JSON
X, Y, Z = [ Ob(FreeCategory.Ob, sym) for sym in [:X, :Y, :Z] ]
f = Hom(:f, X, Y)
g = Hom(:g, Y, Z)
@test to_json(X) == ["Ob", "X"]
@test to_json(f) == ["Hom", "f", ["Ob", "X"], ["Ob", "Y"]]
@test to_json(compose(f,g)) == [
  "compose",
  ["Hom", "f", ["Ob", "X"], ["Ob", "Y"]],
  ["Hom", "g", ["Ob", "Y"], ["Ob", "Z"]],
]

# From JSON
@test parse_json(FreeMonoid, [:Elem, "x"]) == Elem(FreeMonoid, :x)
@test parse_json(FreeMonoid, [:munit]) == munit(FreeMonoid.Elem)
@test parse_json(FreeCategory, ["Ob", "X"]) == X
@test parse_json(FreeCategory, ["Ob", "X"]; symbols=false) ==
  Ob(FreeCategory.Ob, "X")
@test parse_json(FreeCategory, ["Hom", "f", ["Ob", "X"], ["Ob", "Y"]]) == f
@test parse_json(FreeCategory, ["Hom", "f", ["Ob", "X"], ["Ob", "Y"]]; symbols=false) ==
  Hom("f", Ob(FreeCategory.Ob, "X"), Ob(FreeCategory.Ob, "Y"))

# Round trip
@test parse_json(FreeCategory, to_json(compose(f,g))) == compose(f,g)
@test parse_json(FreeCategory, to_json(id(X))) == id(X)

end
