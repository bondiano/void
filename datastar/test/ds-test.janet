(import ../test-support/paths)
(import void/datastar/ds :as ds)

# -- attrs: keywords become data-* names, values keep their shape --------

(def a (ds/attrs :text "$count" :show "$open"))
(assert (= "$count" (a "data-text")))
(assert (= "$open" (a "data-show")))

# the : Datastar puts between a plugin and its argument passes through
(assert (deep= @{"data-on:click" "@post('/inc')"}
           (ds/attrs :on:click "@post('/inc')")))

# dictionaries JSON-encode (data-signals, data-class)
(assert (= `{"count":0}` ((ds/attrs :signals {:count 0}) "data-signals")))

# odd arguments are a readable error
(assert (not (first (protect (ds/attrs :text)))))

# -- action expressions --------------------------------------------------

(assert (= "@post('/inc')" (ds/action :post "/inc")))
(assert (= "@get('/live', {openWhenHidden: true})"
           (ds/action :get "/live" {:open-when-hidden true})))
(assert (= "@get('/x', {contentType: 'form', retryMaxCount: 3})"
           (ds/action :get "/x" {:content-type "form" :retry-max-count 3})))

# -- the named sugar -----------------------------------------------------

(assert (deep= @{"data-signals" `{"count":0}`} (ds/signals {:count 0})))
(assert (deep= @{"data-on:click" "@post('/inc')"} (ds/on :click (ds/action :post "/inc"))))
(assert (deep= @{"data-init" "@get('/live')"} (ds/load (ds/action :get "/live"))))
(assert (deep= @{"data-bind" "query"} (ds/bind :query)))
(assert (deep= @{"data-text" "$count"} (ds/text "$count")))
(assert (deep= @{"data-show" "$open"} (ds/show "$open")))
(assert (deep= @{"data-indicator" "fetching"} (ds/indicator :fetching)))

# builders merge into one attribute table for an element
(assert (deep= @{"data-signals" `{"count":0}`
             "data-on:click" "@post('/inc')"}
           (merge (ds/signals {:count 0})
                  (ds/on :click (ds/action :post "/inc")))))

(print "ds-test: ok")
