### void/mail/render — a mail body is a view (ADR-0026 §4).
###
### There is no template engine here. A mail body is rendered through
### the `:void.html/engine` the composition already selected, so
### hiccup, temple and anything a third party contributed all work for
### mail without knowing that mail exists — and an application writes a
### letter the way it writes a page, with the same components, the same
### `html/escape` and the same layout functions.
###
###     (defn welcome [user]
###       {:subject (string "Welcome, " (user :name))
###        :view [:div [:h1 "Welcome"] [:p [:a {:href (mail/url "/start")} "Start"]]]
###        :layout layouts/mail})
###
###     (mail/send (merge (welcome user) {:to (user :email)}))
###
### **A layout is a function, so it is not config.** `[:mail]` carries
### no `:layout` key: layouts are passed on the message, exactly where
### `html/page` takes them. What *is* config is `[:mail :base-url]`,
### and it has to be, because of the one difference between a page and
### a letter:
###
### **A mail has no origin.** `/static/logo.png` and `/login` resolve
### against nothing in a mail client, so every URL in a letter must be
### absolute. `mail/url` and `mail/asset` build them from
### `[:mail :base-url]`, and a relative link written by hand is not
### silently broken — `check-absolute` finds it and says so, because
### the alternative is a link that works in every test and in no inbox.

(import void/html :as html)

(var base-url
  "The origin a letter's links resolve against — [:mail :base-url],
  installed at boot."
  nil)

(defn- require-base []
  (or base-url
      (error (string "[:mail :base-url] is not set, and a mail has no origin to "
                     "resolve a relative URL against — set it to where this "
                     "application answers, e.g. \"https://example.com\""))))

(defn url
  ``An absolute URL for a path in this application: `[:mail :base-url]`
  plus the path. An argument that is already absolute is returned as
  it is, so a link to somewhere else is not mangled.``
  [path]
  (def s (string path))
  (if (or (string/has-prefix? "http://" s) (string/has-prefix? "https://" s)
          (string/has-prefix? "mailto:" s))
    s
    (string (string/trimr (require-base) "/")
            (if (string/has-prefix? "/" s) s (string "/" s)))))

(defn asset
  "An absolute URL for an asset, through void/html's fingerprint
  manifest — the same file the pages link to, addressed from outside."
  [logical]
  (url (html/asset logical)))

(def- relative-href-peg
  (peg/compile
    ~(any (+ (* (+ "href" "src") (any :s) "=" (any :s) (set "\"'")
                (not (+ "http://" "https://" "mailto:" "cid:" "data:" "#" (set "\"'")))
                (<- (any (if-not (set "\"'") 1))))
             1))))

(defn relative-urls
  "Every href/src in a rendered body that a mail client cannot
  resolve. Empty is what a letter should have."
  [body]
  (or (peg/match relative-href-peg (string body)) []))

(defn check-absolute
  ``Refuse a body with a relative link. Called on the rendered HTML,
  because a URL built by a component is only visible after the
  component ran.``
  [body]
  (def bad (relative-urls body))
  (unless (empty? bad)
    (errorf (string "this mail links to %s, which resolves against nothing in a "
                    "mail client — build links with (mail/url \"/path\")")
            (string/join (map |(string/format "%q" $) (distinct bad)) ", ")))
  body)

(defn render
  ``Render a view through the composition's view engine and return the
  HTML as a string.

  `opts`: `:layout` (as `html/page` takes it), `:engine` (override
  `[:html :engine]` for this letter), `:context` (extra engine
  context) and `:check` (false to allow relative links — an
  application rendering a preview rather than a letter).``
  [view &opt opts]
  (default opts {})
  (def ctx (or html/current-context
               (error (string "void/html is not booted — a mail template is rendered "
                              "by the same engine as a page (add :void/html to "
                              ":plugins)"))))
  (def name (get opts :engine (ctx :engine-name)))
  (def engine
    (or (get-in ctx [:engines name])
        (errorf "unknown view engine %q (contributed: %s)"
                name
                (string/join (map |(string/format "%q" $) (sorted (keys (ctx :engines)))) " "))))
  (def context
    (merge {:mail true} (get opts :context {})
           (if-let [l (get opts :layout)] {:layout l} {})))
  (def body (string ((engine :render) view context)))
  (if (get opts :check true) (check-absolute body) body))

(defn render-message
  ``Turn a message's `:view` into its `:html`. A message that carries
  its HTML already is returned untouched — rendering is a step, not a
  requirement.``
  [msg]
  (if-let [view (get msg :view)]
    (let [html-body (render view {:layout (get msg :layout)
                                  :engine (get msg :engine)
                                  :context (get msg :context {})
                                  :check (get msg :check-urls true)})]
      (-> (merge {} msg)
          (put :html html-body)
          (put :view nil)
          (put :layout nil)
          (put :engine nil)
          (put :context nil)
          (put :check-urls nil)))
    msg))
