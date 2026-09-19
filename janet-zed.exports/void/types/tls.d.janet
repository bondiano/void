# Types of void/tls's values, named where they recur.

# A TLS session over a stream: the table `stream/wrap` builds, a janet stream's
# `:read`/`:write`/`:close` as methods; `:ssl` is nil once closed (or a failed handshake).
(def TlsStream :typedef
  '@{:ssl :pointer? :rbio :pointer :wbio :pointer :raw :any :peer-name :string
    :closed :boolean :enc-buf :buffer :raw-buf :buffer :plain-buf :buffer :len-buf :buffer
    :read (fn [TlsStream :number :buffer? :number?] :buffer?)
    :write (fn [TlsStream (or :string :buffer) :number?] :nil)
    :close (fn [TlsStream] :nil)})
