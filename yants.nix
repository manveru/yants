# Copyright 2019 Google LLC
# SPDX-License-Identifier: Apache-2.0
#
# Provides a "type-system" for Nix that provides various primitive &
# polymorphic types as well as the ability to define & check records.
#
# All types (should) compose as expected.

{ toPretty ? ((import <nixpkgs> {}).lib.generators.toPretty {}) }:

with builtins; let
  typeError = type: val:
  throw "Expected type '${type}', but value '${toPretty val}' is of type '${typeOf val}'";

  typedef = name: check: {
    inherit name check;
    __functor = self: value:
      if check value then value
      else typeError name value;
  };

  poly = n: c: { "${n}" = t: typedef "${n}<${t.name}>" (c t); };

  poly2 = n: c: {
    "${n}" = t1: t2: typedef "${n}<${t1.name},${t2.name}>" (c t1 t2);
  };

  typeSet = foldl' (s: t: s // (if t ? "name" then { "${t.name}" = t; } else t)) {};

  # Struct implementation. Checks that all fields match their declared
  # types, no optional fields are missing and no unexpected fields
  # occur in the struct.
  #
  # Anonymous structs are supported (e.g. for nesting) by omitting the
  # name.
  checkField = def: value: current: field:
  let fieldVal = if hasAttr field value then value."${field}" else null;
      type = def."${field}";
      checked = type.check fieldVal;
  in if checked then (current && true)
     else if isNull fieldVal then (throw "Missing required ${type.name} field '${field}'")
          else  (throw "Field ${field} is of type ${typeOf fieldVal}, but expected ${type.name}");

  checkExtraneous = name: def: present:
  if (length present) == 0 then true
  else if (hasAttr (head present) def)
    then checkExtraneous name def (tail present)
    else (throw "Found unexpected field '${head present}' in struct '${name}'");

  struct' = name: def: {
    inherit name def;
    check = value:
      let fieldMatch = foldl' (checkField def value) true (attrNames def);
          noExtras = checkExtraneous name def (attrNames value);
      in (isAttrs value && fieldMatch && noExtras);

    __functor = self: value: if self.check value then value
      else (throw "Expected '${self.name}'-struct, but ${toPretty value} is of type ${typeOf value}");
  };

  struct = arg: if isString arg then (struct' arg)
                else (struct' "anonymous" arg);

  enum = name: values: rec {
    inherit name values;
    check = (x: elem x values);
    __functor = self: x: if self.check x then x
    else (throw "'${x}' is not a member of enum '${self.name}'");
    match = x: actions: let
      actionKeys = map (__functor { inherit name check; }) (attrNames actions);
      missing = foldl' (m: k: if (elem k actionKeys) then m else m ++ [ k ]) [] values;
    in if (length missing) > 0
       then throw "Missing match action for members: ${toPretty missing}"
       else actions."${__functor { inherit name check; } x}";
  };

  mkFunc = sig: f: {
    inherit sig;
    __toString = self: foldl' (s: t: "${s} -> ${t.name}")
                              "λ :: ${(head self.sig).name}" (tail self.sig);
    __functor = _: f;
  };
  defun' = sig: func: if length sig > 2
    then mkFunc sig (x: defun' (tail sig) (func ((head sig) x)))
    else mkFunc sig (x: ((head (tail sig)) (func ((head sig) x))));

  defun = sig: func: if length sig < 2
    then (throw "Signature must at least have two types (a -> b)")
    else defun' sig func;
in (typeSet [
  # Primitive types
  (typedef "any" (_: true))
  (typedef "int" isInt)
  (typedef "bool" isBool)
  (typedef "float" isFloat)
  (typedef "string" isString)
  (typedef "derivation" (x: isAttrs x && x ? "type" && x.type == "derivation"))
  (typedef "function" (x: isFunction x || (isAttrs x && x ? "__functor"
                                           && isFunction x.__functor)))
  # Polymorphic types
  (poly "option" (t: v: (isNull v) || t.check v))

  (poly "list" (t: v: isList v && (foldl' (s: e: s && (
    if t.check e then true
    else throw "Expected list element of type '${t.name}', but '${toPretty e}' is of type '${typeOf e}'"
  )) true v)))

  (poly "attrs" (t: v: isAttrs v && (foldl' (s: e: s && (
    if t.check e then true
    else throw "Expected attribute set element of type '${t.name}', but '${toPretty e}' is of type '${typeOf e}'"
  )) true (attrValues v))))

  (poly2 "either" (t1: t2: v: t1.check v || t2.check v))
]) // { inherit struct enum defun; }
