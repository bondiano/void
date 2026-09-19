# Types of void/redis's values, named where they recur.

# A value codec: a :void.redis/codec contribution (`codec/raw`, `jdn`, `json`, or a plugin's),
# how a Janet value becomes the bytes redis stores and back. A nil reply is never decoded.
(def RedisCodec :typedef
  '{:name :keyword
   :encode (fn [:any] (or :string :buffer))
   :decode (fn [(or :string :buffer)] :any)})

# What `conn/connection-error` builds and a command throws when the connection itself failed:
# `:fatal` says the connection is gone.
(def RedisConnectionError :typedef
  '{:redis/error :boolean :code :string :fatal :boolean :message :string :server :string})

# What `conn/command-error` builds and a command throws for an error reply: the code, the
# server's text and the command it answered.
(def RedisReplyError :typedef
  '{:redis/error :boolean :code :string :message :string :reply :string :command :string?})
