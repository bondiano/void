(import ../test-support/paths)
(import void/datastar/proto :as proto)
(import void/http/ring :as ring)

# -- patch-elements: the wire format, byte for byte ----------------------

(def ev (proto/patch-elements `<div id="hal">ok</div>`))
(assert (= "datastar-patch-elements" (ev :event)))
(assert (= `elements <div id="hal">ok</div>` (ev :data)))

# multi-line markup: one elements line per line
(def multi (proto/patch-elements "<div>\n  hi\n</div>"))
(assert (= "elements <div>\nelements   hi\nelements </div>" (multi :data)))

# selector, mode and view transition come first, in that order
(def opts (proto/patch-elements "<li>x</li>"
                                {:selector "#list" :mode :append
                                 :use-view-transition true}))
(assert (= (string "selector #list\n"
                   "mode append\n"
                   "useViewTransition true\n"
                   "elements <li>x</li>")
           (opts :data)))

# an unknown mode is a readable error, a verbatim string passes
(assert (not (first (protect (proto/patch-elements "<i>x</i>" {:mode :sideways})))))
(assert (= "mode inner\nelements <i>x</i>"
           ((proto/patch-elements "<i>x</i>" {:mode "inner"}) :data)))

# -- remove --------------------------------------------------------------

(def rm (proto/remove-elements "#toast"))
(assert (= "selector #toast\nmode remove" (rm :data)))

# markup-less patch is only legal as a remove with a selector
(assert (not (first (protect (proto/patch-elements nil)))))
(assert (not (first (protect (proto/patch-elements nil {:mode :remove})))))

# -- patch-signals -------------------------------------------------------

(def sig (proto/patch-signals {:count 2}))
(assert (= "datastar-patch-signals" (sig :event)))
(assert (= `signals {"count":2}` (sig :data)))

(assert (= "onlyIfMissing true\nsignals {\"seen\":true}"
           ((proto/patch-signals `{"seen":true}` {:only-if-missing true}) :data)))

# -- the events frame through ring/sse-event as-is -----------------------

(assert (= (string "event: datastar-patch-elements\n"
                   "data: selector #list\n"
                   "data: mode append\n"
                   "data: useViewTransition true\n"
                   "data: elements <li>x</li>\n"
                   "\n")
           (ring/sse-event opts)))

(print "proto-test: ok")
