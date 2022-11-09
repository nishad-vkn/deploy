{ nixpkgs ? <nixpkgs>
, system ? builtins.currentSystem
}:

let
  pkgs = import nixpkgs { inherit system; };
in {
  manual = with pkgs.lib; with builtins; let
    dummyOpts = let
      mkDummyOption = default: mkOption {
        type = types.unspecified;
        visible = false;
        description = "dummy option";
        inherit default;
      };
    in {
      users.extraUsers = mkDummyOption {};
      networking.hostName = mkDummyOption "localhost";
    };

    modules = evalModules {
      modules = import ./modules/module-list.nix ++ singleton {
        options = dummyOpts;
      };
      args = {
        pkgs = import ./pkgs {
          inherit pkgs;
        };
      };
      check = false;
    };

    filterDoc = filter (opt: opt.visible && !opt.internal);
    optionsXML = toXML (filterDoc (optionAttrSetToDocList modules.options));
    optionsFile = toFile "options.xml" (unsafeDiscardStringContext optionsXML);
  in pkgs.stdenv.mkDerivation {
    name = "opencloud-options";

    buildInputs = singleton pkgs.libxslt;

    xsltFlags = ''
      --param section.autolabel 1
      --param section.label.includes.component.label 1
      --param html.stylesheet 'style.css'
      --param xref.with.number.and.title 1
      --param admon.style '''
    '';

    buildCommand = ''
      xsltproc -o options-db.xml \
        ${<nixpkgs/nixos/doc/manual/options-to-docbook.xsl>} \
        ${optionsFile}

      cat > manual.xml <<XML
      <book xmlns="http://docbook.org/ns/docbook"
            xmlns:xlink="http://www.w3.org/1999/xlink"
            xmlns:xi="http://www.w3.org/2001/XInclude">
        <title>opencloud specific NixOS options</title>
        <para>
          The following NixOS options are specific to the opencloud deployment
        </para>
        <xi:include href="options-db.xml" />
      </book>
      XML

      xsltproc -o "$out/manual.html" $xsltFlags -nonet -xinclude \
        ${pkgs.docbook5_xsl}/xml/xsl/docbook/xhtml/docbook.xsl \
        manual.xml

      cp "${toPath "${nixpkgs}/nixos/doc/manual/style.css"}" "$out/style.css"

      mkdir -p "$out/nix-support"
      echo "doc manual $out manual.html" \
        > "$out/nix-support/hydra-build-products"
    '';
  };

  tests = with pkgs.lib; let
    testsOnly = attrs: !attrs ? test;
  in mapAttrsRecursiveCond testsOnly (_: getAttr "test") (import ./tests {
    pkgs = import ./pkgs { inherit pkgs; };
    inherit system;
  });
}
