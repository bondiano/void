# A product gets a picture (ADR-0039). One nullable text column, and
# what it holds is a **storage key** — "products/2026/09/4f2a1c.png" —
# not a URL: the URL is computed by whichever store the composition
# resolved, so moving this shop from a disk to a bucket is a line of
# config and not a data migration.
#
# Nullable because the seeded catalog has no pictures and a shop with
# no images is still a shop: the widget draws an em dash and the
# storefront falls back to the placeholder.

(defn up []
  [{:alter-table "products"
    :add-column [:image :text]}])

# `void db migrate` runs each migration in one transaction; this one is
# a single statement, because every engine takes exactly one action per
# ALTER TABLE.

(defn down []
  [{:alter-table "products"
    :drop-column :image}])
