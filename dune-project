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
  (decimal
   (>= 1.0))
  (ppx_deriving
   (>= 1.6))))

(package
 (name pera-connector)
 (synopsis "Connector layer for Pera")
 (description "Streaming completion connector layer for the Pera AI agent framework")
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
  (cohttp-eio
   (>= 6.0.0))
  (tls-eio
   (>= 2.0))
  (ca-certs
   (>= 1.0))
  (domain-name
   (>= 0.4))
  (logs
   (>= 0.7))
  (re
   (>= 1.10))
  (uri (>= 4.0.0))
  (ppx_deriving
   (>= 1.6))
  (qcheck-alcotest
   (and
    (>= 0.21)
    :with-test))
  (mirage-crypto-rng ( >= 2.0.0))
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
   (pera-connector
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
   (logs
    (>= 0.7))
   (re
    (>= 1.10))
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
 (name pera-env)
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
  (fpath
   (>= 0.7))
  (ppx_deriving
   (>= 1.6))
  (alcotest
   (and
    (>= 1.7)
    :with-test))))

(package
 (name pera-harness)
 (synopsis "Session logging infrastructure for Pera")
 (description
   "Entry ID generation, session type definitions, JSONL writer, and agent wrapper for the Pera AI agent framework")
 (depends
  (ocaml
   (>= 5.4))
  (pera-types
   (= :version))
  (pera-connector
   (= :version))
  (containers
   (>= 3.0))
  (yojson
   (>= 2.0))
  (uuidm
   (>= 0.9))
  (decimal
   (>= 1.0))
  (ppx_deriving
   (>= 1.6))
  (logs
   (>= 0.7))
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
   (pera-connector
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

(package
 (name pera-tools)
 (synopsis "Tool implementations for Pera")
 (description
   "Tool implementations (read, write, bash, grep) for the Pera AI agent framework")
 (depends
  (ocaml
   (>= 5.4))
  (pera-types
   (= :version))
  (pera-env
   (= :version))
  (pera-core
   (= :version))
  (pera-connector
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
   (alcotest
   (and
    (>= 1.7)
    :with-test))))

(package
 (name pera-agent)
 (synopsis "Assembled agent harness for Pera")
 (description
   "Top-level assembly combining session writer, agent wrapper, and tool execution for the Pera AI agent framework")
 (depends
  (ocaml
   (>= 5.4))
  (pera-types
   (= :version))
  (pera-env
   (= :version))
  (pera-core
   (= :version))
  (pera-connector
   (= :version))
  (pera-harness
   (= :version))
  (pera-tools
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
  (alcotest
   (and
    (>= 1.7)
    :with-test))))

(package
 (name pera-cli)
 (synopsis "Reusable CLI wiring for Pera")
 (description "CLI argument parsing, config loading, and session management for the Pera AI agent framework")
 (depends
  (ocaml (>= 5.4))
  (pera-types (= :version))
  (pera-connector (= :version))
  (pera-core (= :version))
  (pera-env (= :version))
  (pera-harness (= :version))
  (pera-tools (= :version))
  (pera-agent (= :version))
  (containers (>= 3.0))
  (sexplib (>= 0.17))
  (ppx_sexp_conv (>= 0.17))
  (xdg (>= 3.0))
  (cmdliner (>= 1.2))
  (uuidm (>= 0.9))
  (yojson (>= 2.0))
  (fpath (>= 0.7))
  (re (>= 1.0))
  (cstruct (>= 6.0))
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  (eio_linux (>= 1.0))
  (alcotest (and (>= 1.7) :with-test))))

(package
 (name pera_drivers)
 (synopsis "Driver executables for Pera")
 (allow_empty)
 (description
   "Driver executables for Pera - examples of how to use the Pera AI agent framework")
 (depends 
  (cmarkit (>= 0.4.0))
  (logs
   (>= 0.7))
  )
 )
