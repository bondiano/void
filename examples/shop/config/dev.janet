# shop :dev profile.

{:http {:port 8080}

 # a file next to the checkout; `VOID_SHOP_DB=postgres void dev` picks
 # the other driver and reads [:db-postgres] instead
 :db-sqlite {:path "db/shop.sqlite3"}
 :db-postgres {:database "shop_dev"}

 # one process here does everything — serving, enqueueing, running and
 # scheduling. In production those are two deployments off one image
 # (see docker-compose.yml), which is why both switches are off by
 # default and turned on here.
 :jobs {:worker {:enabled true :queues [:default :payments :mail :maintenance]}
        :scheduler {:enabled true}}

 # a span per line is how tracing is visible before there is a
 # collector; :always because in development the interesting request is
 # the one nobody sent a traceparent for
 :obs {:trace {:always true :exporter :log}}}
