### void/dash/live — the Datastar half, armed only by composition
### (the module-edge pose of void/storage/sign).
###
### This module imports void/datastar — the package edge is real — but
### the *plugin* is the application's opt-in: when :void/datastar is
### not in :plugins there is no registry component, `active?` answers
### false, the overview carries no data-init attribute and every
### page falls back to the htmx poll of M1. When it is, the overview
### and the log page live on a morph-stream: each update re-renders
### the whole page and Datastar morphs the delta into the DOM — the
### page *is* the state, which is the idiom the experiment is waiting to
### judge on a real consumer.

(import void/datastar/init :as datastar)
(import ./context :as ctx)

(def overview-room
  "The room the history sampler pokes — every open overview re-renders."
  :void.dash/overview)

(def logs-room
  "The room the log sink pokes — every open log page re-renders.
  poke! coalesces, so a burst of records is one render."
  :void.dash/logs)

(defn active?
  "Is the live half armed — void/datastar composed and its registry
  running?"
  []
  (and (ctx/setting :datastar?)
       (truthy? datastar/current-registry)))

(defn poke!
  "Wake a room, if the live half is armed; never throws — a dashboard
  must not take a log sink or a sampler down with it."
  [room]
  (when (active?)
    (protect (datastar/poke! room)))
  nil)

(defn stream
  ``A morph-stream over `view` (a function of no arguments returning
  the full page as hiccup), or the refusal that names the plugin when
  the live half is not armed.``
  [req view rooms]
  (if (active?)
    (datastar/morph-stream req view {:rooms rooms})
    @{:status 404
      :headers @{"content-type" "text/plain; charset=utf-8"}
      :body "the live stream is not armed: :void/datastar is not in this composition — the pages poll over htmx instead, which is the same data 5 seconds later."}))
