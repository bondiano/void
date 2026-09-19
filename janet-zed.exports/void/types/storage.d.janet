# Types of void/storage's values, named where they recur.

# An object's metadata: what a store's :put! and :stat answer — plus whatever the backend
# knows (s3's :etag, the local store's :modified), hence open.
(def StorageMeta :typedef
  '{:key :string :size :number :content-type :any & r})

# What `upload/save-part!` answers: the store's metadata plus the part's filename.
(def StorageUpload :typedef
  '{:key :string :size :number :content-type :any :filename :string & r})

# A :void/storage-store after `store/normalize`: the five required functions, the two
# optional ones filled in, and the declarations (store.janet says what each one means).
(def StorageStore :typedef
  '{:name :keyword
   :shared? :boolean
   :replacement :string?
   :put! (fn [:string :any (or {:content-type :any? & r} :nil)] StorageMeta)
   :get (fn [:string] :any)
   :stream (fn [:string] :any)
   :delete! (fn [:string] :boolean)
   :stat (fn [:string] StorageMeta?)
   :url (fn [:string (or {:expires :number? & r} :nil)] :string?)
   :close (fn [] :any)
   & r})
