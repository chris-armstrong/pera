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
   (>= 2.0))
  (ppx_deriving
   (>= 1.6))))

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
  (logs
   (>= 0.7))
  (re
   (>= 1.10))
  (ppx_deriving
   (>= 1.6))
  (qcheck-alcotest
   (and
    (>= 0.21)
    :with-test))
  (qcheck-core
   (and
    (>= 0.21)
    :with-test))))

(package
 (name pera-core)
 (synopsis "Pera agent core loop")
 (description
  "Agent loop, hooks, and tool execution")
 (depends
   (ocaml
    (>= 5.4))
   (pera-types
    (= :version))
   (pera-provider
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
   (ppx_deriving
    (>= 1.6))
   (qcheck-core
    (and
     (>= 0.21)
     :with-test))
   (qcheck-alcotest
    (and
     (>= 0.21)
     :with-test))))

(package
 (name pera-harness)
 (synopsis "Execution environment for Pera")
 (description
   "Execution environment abstraction and OS-backed implementation for the Pera AI agent framework")
 (depends
  (ocaml
   (>= 5.4))
  (pera-types
   (= :version))
  (containers
   (>= 3.0))
  (eio
   (>= 1.0))
  (eio_main
   (>= 1.0))
  (eio_linux
   (>= 1.0))
  (unix
   (>= 5.4))
  (fpath
   (>= 0.7))
  (ppx_deriving
   (>= 1.6))
  (alcotest
   (and
    (>= 1.7)
    :with-test))))

(package
 (name pera-core-test-util)
 (synopsis "Test utilities for pera-core")
 (description
   "Test doubles and Alcotest testables for pera-core consumers")
 (depends
   (ocaml
    (>= 5.4))
   (pera-types
    (= :version))
   (pera-provider
    (= :version))
   (pera-core
    (= :version))
   (containers
    (>= 3.0))
   (yojson
    (>= 2.0))
   (eio
    (>= 1.0))
   (eio_main
    (>= 1.0))
   (alcotest
    (>= 1.7))
   (ppx_deriving
    (>= 1.6))))
