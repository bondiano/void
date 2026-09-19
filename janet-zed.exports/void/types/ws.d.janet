# Types of void/ws's values, named where they recur.

# An application message, tagged by its frame kind: what a connection's :on-message handler
# and `client/receive` are handed, and what `wshtmx/fields` and `headers` decode.
(def WsMessage :typedef
  '(or {:type :text :data :string}
      {:type :binary :data :string}))

# The peer's close frame, as `client/receive` answers it.
(def WsClose :typedef
  '{:type :close :code :number :name :keyword? :reason :string})
