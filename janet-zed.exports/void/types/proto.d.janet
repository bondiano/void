# Types of void/proto's values, named where they recur.

# One normalized field (descriptor.janet `field`): its number, label and wire type, plus
# :key/:value for a map, :ref for a message or enum, :oneof, :deprecated, :doc.
(def ProtoField :typedef
  '{:name :keyword :number :number :label :keyword :type :keyword
   :json-name :string :packed :boolean & r})

# A message descriptor: the frozen struct `descriptor/message` builds.
(def ProtoMessage :typedef
  '{:kind :message :name :keyword :proto-name :string :fields [ProtoField]
   :by-number @{:number ProtoField} :by-name @{:keyword ProtoField}
   :by-json @{:string ProtoField} :oneofs @{:keyword @[:keyword]} :reserved [:string]
   :doc :string?})

# An enum descriptor: the frozen struct `descriptor/enum` builds.
(def ProtoEnum :typedef
  '{:kind :enum :name :keyword :proto-name :string :values {:keyword :number}
   :by-number @{:number :keyword} :zero :keyword :allow-alias :boolean :doc :string?})

# One normalized RPC method (descriptor.janet `method`).
(def ProtoMethod :typedef
  '{:name :keyword :input :keyword :output :keyword :proto-name :string
   :client-streaming :boolean :server-streaming :boolean :idempotent :boolean})

# A service descriptor: the frozen struct `descriptor/service` builds.
(def ProtoService :typedef
  '{:kind :service :name :keyword :proto-name :string :methods [ProtoMethod]
   :by-name @{:keyword ProtoMethod} :doc :string?})

# What the registry holds under a name: tagged by :kind.
(def ProtoDescriptor :typedef
  '(or ProtoMessage ProtoEnum ProtoService))

# A message as the codecs take it: the descriptor, or the name it is registered under.
(def ProtoMessageRef :typedef
  '(or {:kind :keyword & r} :keyword :string :buffer))
