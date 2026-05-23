(lang dune 3.16)

(name pera)

(generate_opam_files true)

(source
 (github chris-armstrong/pera))

(authors "Chris Armstrong")

(maintainers "carmstrong@fastmail.com.au")

(package
 (name pera-types)
 (synopsis "Core data model types for Pera")
 (description "Pure type definitions for the Pera AI agent framework")
 (depends
  (ocaml
   (>= 5.4))
  (containers
   (>= 3.0))
  (yojson
   (>= 2.0))))

(package
 (name pera-provider)
 (synopsis "Provider layer for Pera")
 (description "Streaming completion provider layer for the Pera AI agent framework")
 (depends
  (ocaml
   (>= 5.4))
  (pera-types
   (= :version))
  (containers
   (>= 3.0))
  (yojson
   (>= 2.0))
  (eio
   (>= 1.0))
  (eio_main
   (>= 1.0))
  (eio_linux
   (>= 1.0))
  (piaf
   (>= 0.2))
  (re
   (>= 1.10))))
