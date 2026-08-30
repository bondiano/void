;;; Directory Local Variables            -*- no-byte-compile: t -*-
;;; Sent to a freshly started Janet REPL (see +janet-repl-init-forms in the
;;; Doom config): nothing under void/ is importable until the checkout's
;;; packages are on module/paths, which is what scripts/packages does for
;;; scripts/void and jpm test alike.
;;;
;;; Two separate forms, not one `do': `import' binds at compile time, so a
;;; single form referring to packages/... would not compile.

((nil . ((+janet-repl-init-forms
          . ("(do (import ./scripts/packages :as packages) :void/packages)"
             "(do (packages/add-paths (packages/packages)) :void/paths-ready)")))))
