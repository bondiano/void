# Types of void/fdwait's values.

# Both directions of one descriptor: the table `pair` builds, each watcher created and cached
# on first `await` under the direction it waits on.
(def FdwaitPair :typedef
  '@{:fd :number :read :abstract? :write :abstract? :both :abstract?})
