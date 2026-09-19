# Types of void/notify's values, named where they recur.

# A notification after `notification/normalize`: what every channel reads. `:overrides` holds
# each channel's own keys, by channel name.
(def NotifyNotification :typedef
  '@{:id :string :at :number :key :keyword :title :string :body :string?
    :url :string? :data {:any :any} :to :any :channels [:keyword]
    :overrides @{:keyword {:any :any}}})

# One in-app notification as the store reads it back (`store/row->record`).
(def NotifyRecord :typedef
  '@{:id :any :recipient :any :key :keyword :title :any :body :any :url :any
    :data {:any :any} :created :any :seen :any :read? :boolean})
