{ mkDerivation, base, bifunctors, checkers, containers, derive
, hspec, mtl, QuickCheck, stdenv, text
}:
mkDerivation {
  pname = "reform";
  version = "0.2.7.1";
  src = ./.;
  libraryHaskellDepends = [ base bifunctors containers mtl text ];
  testHaskellDepends = [ base checkers derive hspec QuickCheck ];
  homepage = "http://www.happstack.com/";
  description = "reform is a type-safe HTML form generation and validation library";
  license = stdenv.lib.licenses.bsd3;
}
