# Types of void/admin's values, named where they recur.

# One field of a resource's entity as the pages see it: resource.janet `field-info`, the
# record every column, filter and form field is made of.
(def AdminField :typedef
  '{:name :keyword :label (or :string :keyword :nil) :required :boolean
   :node :any :schema :any :type :keyword :column :string :db {:keyword :any}
   :pk :boolean :version :boolean :rel :any})

# A `:list`/`:detail` column (`field-descriptor`): a field, or a computed `:value` with none.
(def AdminColumn :typedef
  '{:name :keyword :label :any :field AdminField? & r})

# A filter (`filter-descriptor`): the field it narrows and the query parameter it reads.
(def AdminFilter :typedef
  '{:label :any :param :string :name :keyword :field AdminField & r})

# A custom action (`action-descriptor`).
(def AdminAction :typedef
  '{:name :keyword :label :any :needs-selection :boolean :danger :boolean & r})

# An inline — a relation edited on its parent's page (`inline-descriptor`).
(def AdminInline :typedef
  '{:name :keyword :label :any :style :keyword :per-page :number
   :can-add :boolean :can-delete :boolean :resource :keyword :rel DbRelation & r})

# A resource descriptor: what `resource/resource` freezes, the one declaration `mount` and `mcp`
# both project.
(def AdminResource :typedef
  '{:name :keyword
   :doc :any
   :entity DbEntity
   :title :string :singular :string :path :string :mount :boolean
   :group :string?
   :actions [:keyword]
   :action-set {:keyword :boolean}
   :custom-actions {:keyword AdminAction}
   :list [AdminColumn]
   :detail [AdminColumn]
   :list-derived? :boolean :detail-derived? :boolean
   :form [:keyword]
   :form-schema SchemaNode
   :form-fields [AdminField]
   :readonly [:keyword]
   :filters [AdminFilter]
   :search [:keyword] :sortable [:keyword] :editable [:keyword]
   :order-by :any :per-page :number? :preload :any
   :scope (or (fn [HttpRequest] :any) :nil)
   :defaults {:keyword (fn [HttpRequest] :any)}
   :slots {:keyword {:keyword (fn [:any] :tuple)}}
   :widgets {:keyword :any}
   :inlines {:keyword AdminInline}})

# The job listing a jobs page URL describes (jobs.janet `listing-state`); nil is "any".
(def AdminJobsListing :typedef
  '{:queue :keyword? :state :keyword? :job :keyword? :limit :number :default-limit :number})
